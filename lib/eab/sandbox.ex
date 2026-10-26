defmodule Eab.Sandbox do
  alias Eab.{AgentImage, Command, Inventory, Store}

  def with_box(id, run_id, fun, opts \\ []) do
    runtime = Store.read("runtimes/#{id}.json") || raise "Fixture is not prepared"

    unless runtime["fixture_hashes"] == Inventory.fixture_hashes(id),
      do: raise("Fixture changed after preparation")

    with_runtime(id, Inventory.spec(id), runtime, run_id, fun, opts)
  end

  def with_runtime(id, spec, runtime, run_id, fun, opts \\ []) do
    Eab.Retention.with_use(fn -> start_runtime(id, spec, runtime, run_id, fun, opts) end)
  end

  defp start_runtime(id, spec, runtime, run_id, fun, opts) do
    runtime =
      if opts[:agent],
        do: Map.put(runtime, "image", AgentImage.ensure(spec, runtime["image"])),
        else: runtime

    name = "eab-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    box = %{name: name, id: id, spec: spec, runtime: runtime, run_id: run_id}

    try do
      start(box, opts)
      fun.(box)
    after
      for suffix <- ["", "-ch", "-db"],
          do: Command.run("docker", ["rm", "-f", "-v", name <> suffix], timeout: 30)
    end
  end

  defp start(box, opts) do
    services = box.runtime["services"]
    labels = ["--label", "eab.installation=#{installation()}", "--label", "eab.run=#{box.run_id}"]
    network = if services["postgres"], do: "container:#{box.name}-db", else: "none"

    if services["postgres"] do
      Command.run!(
        "docker",
        ["run", "-d", "--name", box.name <> "-db", "--network=none", "--memory=512m", "--cpus=1"] ++
          labels ++ ["-e", "POSTGRES_PASSWORD=postgres", services["postgres"]]
      )

      Command.run!(
        "docker",
        [
          "exec",
          box.name <> "-db",
          "sh",
          "-c",
          "for i in $(seq 1 60); do pg_isready -h 127.0.0.1 -U postgres && exit 0; sleep 1; done; exit 1"
        ],
        timeout: 90
      )
    end

    if services["clickhouse"] do
      unless services["postgres"],
        do: raise("ClickHouse requires an isolated PostgreSQL network namespace")

      Command.run!(
        "docker",
        [
          "run",
          "-d",
          "--name",
          box.name <> "-ch",
          "--network=#{network}",
          "--memory=3g",
          "--cpus=2",
          "--ulimit",
          "nofile=262144:262144"
        ] ++ labels ++ ["-e", "CLICKHOUSE_SKIP_USER_SETUP=1", services["clickhouse"]]
      )

      Command.run!(
        "docker",
        [
          "exec",
          box.name <> "-ch",
          "sh",
          "-c",
          "for i in $(seq 1 90); do clickhouse-client --query 'SELECT 1' && exit 0; sleep 1; done; exit 1"
        ],
        timeout: 120
      )
    end

    Command.run!(
      "docker",
      [
        "run",
        "-d",
        "--name",
        box.name,
        # Reaps orphaned processes, which would otherwise count against the pids limit.
        "--init",
        "--network=#{network}",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        "--memory=4g",
        "--cpus=2",
        "--pids-limit=512",
        "--tmpfs=/tmp:rw,nosuid,size=512m"
      ] ++ labels ++ [box.runtime["image"]]
    )

    commands =
      if Keyword.get(opts, :before_test, true),
        do: box.spec["runtime"]["before_test_commands"] || [],
        else: []

    for cmd <- commands,
        do: command!(box, cmd, timeout: 240)
  end

  def command(box, command, opts \\ []) do
    timeout = opts[:timeout] || 120

    Command.run(
      "docker",
      [
        "exec",
        "-w",
        "/workspace",
        box.name,
        "timeout",
        "-k",
        "5",
        to_string(timeout),
        "bash",
        "-lc",
        command
      ],
      timeout: timeout + 15,
      limit: opts[:limit] || 20_000,
      quiet: opts[:quiet]
    )
  end

  def command!(box, cmd, opts \\ []) do
    result = command(box, cmd, opts)

    if result["returncode"] != 0 or result["output_truncated"],
      do: raise("Workspace command failed: #{result["output"]}")

    result["output"]
  end

  def apply_patch(_box, patch) when patch in ["", nil], do: :ok

  def apply_patch(box, patch) do
    file = Store.path("scratch/#{box.name}.patch")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, patch)

    try do
      copy_file(box, file, "/opt/eab-grade/patch.diff")
      command!(box, "git apply --whitespace=nowarn /opt/eab-grade/patch.diff")
    after
      File.rm(file)

      Command.run("docker", ["exec", "-u", "0", box.name, "rm", "-f", "/opt/eab-grade/patch.diff"])
    end
  end

  # Agents snapshot the patch after every tool call; echoing it would repeat the
  # whole diff in the activity log each time.
  def patch(box) do
    command!(box, "git add -A && git diff --cached --binary HEAD",
      limit: 1_048_576,
      timeout: 60,
      quiet: true
    )
  end

  def formatter(box) do
    copy_file(
      box,
      Inventory.path("priv/fixtures/grade_formatter.exs"),
      "/opt/eab-grade/formatter.exs"
    )
  end

  def copy_file(box, source, destination) do
    # Write as container root: Docker archive copies can retain the controller's
    # UID or land underneath tmpfs mounts. Neither should affect worker inputs.
    body = File.read!(source)
    target = Command.quote(destination)

    script =
      "mkdir -p #{Command.quote(Path.dirname(destination))} && rm -f #{target} && " <>
        "head -c #{byte_size(body)} > #{target} && chmod 444 #{target}"

    Command.run!("docker", ["exec", "-i", "-u", "0", box.name, "sh", "-c", script], input: body)
  end

  def installation do
    case Store.read("installation.json") do
      %{"id" => id} ->
        id

      nil ->
        id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        Store.write("installation.json", %{"id" => id})
        id
    end
  end

  def cleanup(run_id) do
    result =
      Command.run(
        "docker",
        [
          "ps",
          "-aq",
          "--filter",
          "label=eab.installation=#{installation()}",
          "--filter",
          "label=eab.run=#{run_id}"
        ],
        timeout: 30
      )

    if result["returncode"] != 0, do: raise("Cannot inspect owned containers for cleanup")

    for id <- String.split(result["output"]),
        do: Command.run!("docker", ["rm", "-f", "-v", id], timeout: 30)

    :ok
  end
end
