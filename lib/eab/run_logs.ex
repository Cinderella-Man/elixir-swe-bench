defmodule Eab.RunLogs do
  @moduledoc """
  Keeps a run's full logs with the repository (ADR 0023). `save!/2` copies them out of the
  controller's data folder into `verification/runs/run-<id>/`:

      manifest.json                        every file below with its size and SHA-256
      run-summary.json                     what was run: release, case files, harness, model, settings
      calls.json                           prompt and output tokens of every model call
      claude-code-hooks.jsonl              a Claude Code run's hook decisions
      <case>/grade-summary.json            the outcome and the attempt's totals
      <case>/instructions.md               what the agent was told
      <case>/model.patch                   the patch as submitted
      <case>/logs/activity.log             the controller's log of the attempt
      <case>/logs/pi-events.jsonl          Pi's event stream, or
      <case>/logs/claude-transcript.jsonl  the Claude Code transcript
      <case>/logs/grade.json               the grader's full output

  The repository is public, so three things are replaced wherever they occur: the Claude
  account's organization ID, its email address and the names of the machine that served the
  model. Nothing else is changed. The controller's copies of every request and response are
  left out: they repeat the conversation the event stream holds and are far larger. So are
  each call's timing and the run's own record, which names machines.

  The folder is written whole or not at all: it is staged beside its place and renamed, and
  `manifest.json` is its last file.
  """
  alias Eab.{ContextSize, Inventory, Store}

  @format 1
  @checks ~w(hidden regression submission)
  # A case's files in the data folder, and where each is kept.
  @case_files [
    {"instructions.md", "instructions.md"},
    {"model.patch", "model.patch"},
    {"activity.log", "logs/activity.log"},
    {"pi-events.jsonl", "logs/pi-events.jsonl"},
    {"claude-transcript.jsonl", "logs/claude-transcript.jsonl"},
    {"grade.json", "logs/grade.json"}
  ]

  def root,
    do:
      Application.get_env(:eab, :run_logs_root) ||
        Path.join([Application.get_env(:eab, :root, File.cwd!()), "verification", "runs"])

  def directory(run_id, opts \\ []), do: Path.join(opts[:root] || root(), "run-" <> run_id)

  @doc "Whether a run's logs are saved: its folder is complete once it holds a manifest."
  def saved?(run_id, opts \\ []) do
    Store.valid_id?(run_id) and
      File.regular?(Path.join(directory(run_id, opts), "manifest.json"))
  end

  @doc """
  Checks a saved folder against its manifest, for a copy carried from another machine: every
  listed file is there with its size and hash, and no other file is. Returns `:ok` or the
  problems found.
  """
  def check(run_id, opts \\ []) do
    folder = directory(run_id, opts)

    case Store.valid_id?(run_id) && File.read(Path.join(folder, "manifest.json")) do
      {:ok, body} ->
        files = Jason.decode!(body)["files"]

        wrong =
          for {relative, %{"bytes" => bytes, "sha256" => hash}} <- files,
              problem = mismatch(Path.join(folder, relative), bytes, hash),
              do: "#{relative}: #{problem}"

        extra =
          for path <- Path.wildcard(Path.join(folder, "**"), match_dot: true),
              File.regular?(path),
              relative = Path.relative_to(path, folder),
              relative != "manifest.json" and not is_map_key(files, relative),
              do: "#{relative}: not in the manifest"

        if wrong ++ extra == [], do: :ok, else: {:error, Enum.sort(wrong ++ extra)}

      _ ->
        {:error, ["manifest.json: missing"]}
    end
  end

  defp mismatch(path, bytes, hash) do
    case File.read(path) do
      {:ok, body} when byte_size(body) == bytes ->
        if Inventory.hash(body) != hash, do: "changed"

      {:ok, _} ->
        "changed"

      _ ->
        "missing"
    end
  end

  @doc "`save!/2` with its failure as a message."
  def save(run, opts \\ []) do
    {:ok, save!(run, opts)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc """
  Saves the run's logs, replacing an earlier copy. Returns the folder, how many files and
  bytes it holds and how many replacements were made.
  """
  def save!(run, opts \\ []) do
    require!(
      is_map(run) and Store.valid_id?(run["id"]) and is_list(run["cases"]) and
        Enum.all?(run["cases"], &Store.valid_id?/1),
      "Expected a run"
    )

    id = run["id"]
    source = Store.path("runs/#{id}")
    require!(File.dir?(source), "The files of run #{id} are not in the data folder")
    root = opts[:root] || root()
    home = Path.dirname(root)

    # Inside the container a folder that is not mounted would be lost with the container.
    require!(
      File.dir?(home),
      "#{home} does not exist. Mount the checkout's verification folder there."
    )

    owned_dir!(root, home)
    final = directory(id, opts)
    stage = Path.join(root, ".run-#{id}-#{random()}")
    File.mkdir_p!(stage)

    try do
      secrets = secrets(run, source)
      put = fn relative, body -> put!(stage, relative, body, secrets) end
      hooks = Path.join(source, "claude-code-hooks.jsonl")

      entries =
        [put.("run-summary.json", json(run_summary(run)))] ++
          if(File.regular?(hooks),
            do: [put.("claude-code-hooks.jsonl", File.read!(hooks))],
            else: []
          ) ++
          Enum.flat_map(run["cases"], &save_case(run, source, &1, put)) ++
          [put.("calls.json", calls_json(run))]

      manifest = %{
        "format" => @format,
        "run_id" => id,
        "files" =>
          Jason.OrderedObject.new(
            for {relative, bytes, hash, _} <- Enum.sort(entries),
                do: {relative, %{"bytes" => bytes, "sha256" => hash}}
          )
      }

      File.write!(Path.join(stage, "manifest.json"), json(manifest))
      for path <- [stage | Path.wildcard(Path.join(stage, "**"))], do: inherit_owner!(path, home)
      replace!(stage, final)

      %{
        "path" => final,
        "files" => length(entries) + 1,
        "bytes" => entries |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
        "replacements" => entries |> Enum.map(&elem(&1, 3)) |> Enum.sum()
      }
    after
      File.rm_rf!(stage)
    end
  end

  defp save_case(run, source, case_id, put) do
    directory = Path.join(source, case_id)

    attempt =
      get_in(run, ["attempts", case_id]) ||
        Store.read("runs/#{run["id"]}/#{case_id}/attempt.json") || %{}

    copied =
      for {from, to} <- @case_files, File.regular?(Path.join(directory, from)) do
        put.(Path.join(case_id, to), File.read!(Path.join(directory, from)))
      end

    patch_hash =
      Enum.find_value(copied, fn {relative, _, hash, _} ->
        if relative == Path.join(case_id, "model.patch"), do: hash
      end)

    grade = Store.read("runs/#{run["id"]}/#{case_id}/grade.json")
    summary = grade_summary(run, case_id, attempt, grade, patch_hash)
    copied ++ [put.(Path.join(case_id, "grade-summary.json"), json(summary))]
  end

  defp grade_summary(run, case_id, attempt, grade, patch_hash) do
    graded =
      if is_map(grade) do
        checks =
          Map.new(@checks, fn check ->
            result = grade[check] || %{}
            tests = if is_map(result["test_results"]), do: result["test_results"], else: %{}
            failed = for {name, state} <- tests, state not in ~w(passed excluded), do: name

            {check,
             %{
               "passed" => result["passed"],
               "tests" => map_size(tests),
               "failed" => Enum.sort(failed)
             }}
          end)

        Map.merge(checks, %{
          "regression_coverage" => get_in(grade, ["regression_coverage", "passed"]),
          "submitted_test_files" => grade["submitted_test_files"] || []
        })
      else
        %{"error" => attempt["error"]}
      end

    harness = run["harness"] || %{}

    agent =
      case attempt["claude_code"] do
        %{} = solver ->
          %{
            "model" =>
              List.first(solver["resolved_models"] || []) || get_in(run, ["model", "model"]),
            "agent" => harness["agent"],
            "kit_sha256" => harness["kit_sha256"],
            "claude_code_version" => solver["claude_code_version"],
            "solver_agent_id" => solver["agent_id"],
            "compactions" => solver["compactions"]
          }

        _ ->
          %{"agent" => harness["package"], "agent_version" => harness["version"]}
      end

    %{
      "case" => case_id,
      "status" => attempt["status"],
      "passed" => get_in(attempt, ["grade", "passed"]),
      "model_patch_sha256" => patch_hash,
      "stop_reason" => attempt["stop_reason"],
      "model_calls" => attempt["calls"],
      "generated_tokens" => attempt["generated_tokens"],
      "peak_context_tokens" => ContextSize.of_attempt(run["id"], case_id, attempt)
    }
    |> Map.merge(graded)
    |> Map.merge(agent)
  end

  # What was run, without the run record's machine names, memory samples and server metadata.
  defp run_summary(run) do
    model = run["model"] || %{}
    identity = if is_map(model["identity"]), do: model["identity"], else: %{}
    artifact = identity["artifact"]

    %{
      "format" => @format,
      "run_id" => run["id"],
      "created_at" => run["created_at"],
      "status" => run["status"],
      "benchmark" => get_in(run, ["protocol", "inventory", "id"]),
      "release_id" => run["release_id"],
      "code_versions" => run["code_versions"],
      "harness" => run["harness"],
      "model" => %{
        "backend" => model["backend"],
        "api_model" => model["model"],
        "context_tokens" => model["context"],
        "identity" =>
          Map.put(identity, "artifact", if(is_binary(artifact), do: Path.basename(artifact))),
        "source" => model["source"]
      },
      "settings" => run["settings"],
      "parallel_attempts" => run["parallel_attempts"] || 1,
      "selection" => run["selection"],
      "score" => run["score"],
      "cases" => run["cases"],
      "case_fixtures" => get_in(run, ["protocol", "fixtures"])
    }
  end

  # One line per case keeps a run's thousands of calls readable and its diffs small.
  defp calls_json(run) do
    lines =
      Enum.map_join(run["cases"], ",\n", fn case_id ->
        calls =
          Enum.map_join(ContextSize.calls(run["id"], case_id), ",", fn {prompt, output} ->
            "[#{prompt},#{output}]"
          end)

        "    #{Jason.encode!(case_id)}: [#{calls}]"
      end)

    """
    {
      "run_id": #{Jason.encode!(run["id"])},
      "fields": ["prompt_tokens", "output_tokens"],
      "cases": {
    #{lines}
      }
    }
    """
  end

  # The account a Claude Code run was signed in to, and the machine that served the model.
  defp secrets(run, source) do
    account =
      for path <- Path.wildcard(Path.join(source, "*/claude-transcript.jsonl")),
          line <- File.stream!(path),
          {pattern, mask} <- account_patterns(),
          [_, found] <- Regex.scan(pattern, line),
          uniq: true,
          do: {found, mask}

    # Longest first, so a name inside a longer one does not split it.
    account =
      account
      |> Enum.sort_by(fn {needle, _} -> -byte_size(needle) end)
      |> Enum.map(fn {needle, mask} -> {Regex.compile!(Regex.escape(needle)), mask} end)

    account ++ machine_patterns(run)
  end

  defp account_patterns do
    [
      {~r/"organizationUuid"\s*:\s*"([0-9a-f-]{20,})"/, "[redacted organization]"},
      {~r/email address is ([^\s\\"<]+@[^\s\\"<]+?)\.?(?=[\\"\s<])/, "[redacted email]"},
      {~r/"(?:email|emailAddress|accountEmail)"\s*:\s*"([^"\\]+@[^"\\]+)"/, "[redacted email]"}
    ]
  end

  # The names of the machine that served the model: the endpoint's host, its tailnet, and the
  # host and service the memory collector reported. A name with a dot or an `@` is replaced
  # wherever it occurs. A bare one could be an ordinary word, so it is replaced only where it
  # is written as an address: after `//` or `@`, or before a port.
  defp machine_patterns(run) do
    host =
      case get_in(run, ["model", "url"]) do
        "http" <> _ = url -> URI.parse(url).host
        _ -> nil
      end

    # A tailnet's name identifies its owner as much as the machine's does.
    tailnet =
      if is_binary(host) and String.ends_with?(host, ".ts.net"),
        do: host |> String.split(".") |> Enum.take(-3) |> Enum.join(".")

    sessions =
      case get_in(run, ["memory", "sessions"]) do
        sessions when is_list(sessions) -> sessions
        _ -> []
      end

    collected =
      for session <- sessions,
          is_map(session),
          key <- ~w(host service),
          do: get_in(session, ["identity", key])

    [host, tailnet | collected]
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= 4))
    |> Enum.reject(&(String.downcase(&1) in ~w(localhost 127.0.0.1 host.docker.internal)))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.sort_by(&(-byte_size(&1)))
    |> Enum.map(fn name ->
      escaped = Regex.escape(name)

      pattern =
        if String.contains?(name, [".", "@", ":"]),
          do: escaped,
          else: "(?<=//|@)#{escaped}(?![\\w.-])|(?<![\\w.-])#{escaped}(?=:\\d)"

      {Regex.compile!(pattern, "i"), "[redacted host]"}
    end)
  end

  defp put!(stage, relative, body, secrets) do
    {body, replaced} =
      Enum.reduce(secrets, {body, 0}, fn {pattern, mask}, {body, count} ->
        case length(Regex.scan(pattern, body, return: :index)) do
          0 -> {body, count}
          found -> {Regex.replace(pattern, body, mask), count + found}
        end
      end)

    path = Path.join(stage, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    {relative, byte_size(body), Inventory.hash(body), replaced}
  end

  defp replace!(stage, final) do
    old = final <> ".old-#{random()}"
    if File.exists?(final), do: File.rename!(final, old)
    File.rename!(stage, final)
    File.rm_rf!(old)
  end

  defp owned_dir!(path, owner) do
    unless File.dir?(path) do
      File.mkdir_p!(path)
      inherit_owner!(path, owner)
    end
  end

  # The Docker release runs as root; keep bind-mounted outputs editable by the checkout owner.
  defp inherit_owner!(path, owner) do
    %{uid: uid, gid: gid} = File.stat!(owner)
    File.chown!(path, uid)
    File.chgrp!(path, gid)
  end

  defp json(value), do: Jason.encode!(value, pretty: true) <> "\n"
  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  defp require!(true, _), do: true
  defp require!(_, message), do: raise(ArgumentError, message)
end
