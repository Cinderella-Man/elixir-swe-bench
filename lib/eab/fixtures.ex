defmodule Eab.Fixtures do
  alias Eab.{
    Baseline,
    Browser,
    BuildCache,
    Cache,
    Command,
    DatabaseSeed,
    Inventory,
    ServiceImages,
    Source,
    Store
  }

  # An unpinned Hex install follows whatever is newest when an image is rebuilt.
  @hex_version "2.5.3"

  # Mix before Elixir 1.13 ignores `mix local.hex VERSION`, so those images install
  # the same release directly. Checksums: https://builds.hex.pm/installs/hex-1.x.csv
  @hex_builds %{
    "1.12" =>
      {"1.12.0",
       "9a485c1739d61bb56072f388688ad5c754eada53df9050c109757dc0d6130688c089d84891281a21838a485ade0066921482487d1eb72732bbb0d641b884bef4"}
  }

  def ensure(id, emit, opts \\ []) do
    Eab.Retention.with_use(fn -> do_ensure(id, emit, opts) end)
  end

  # Planning can skip all ancestry for exact, physically present baselines.
  # ensure/3 still validates each component before use. No build or bootstrap
  # occurs during this probe, and a partial/missing record goes down the cold path.
  def cached?(id, opts \\ []) do
    exists? = Keyword.get(opts, :image_exists?, &image_exists?/1)

    case cached_images(id) do
      {:ok, images} -> Enum.all?(images, exists?)
      _ -> false
    end
  end

  def cached_cases(ids) do
    candidates = for id <- ids, {:ok, images} <- [cached_images(id)], do: {id, images}
    present = Eab.ImagePresence.existing(Enum.flat_map(candidates, &elem(&1, 1)))

    for {id, images} <- candidates,
        Enum.all?(images, &MapSet.member?(present, &1)),
        into: MapSet.new(),
        do: id
  end

  defp cached_images(id) do
    spec = Inventory.spec(id)
    inputs = build_inputs(id, spec)
    engines = %{"services" => spec["services"] || %{}}
    opts = [image_exists?: fn _ -> true end]

    with {:ok, project} <- Cache.lookup("projects", Cache.key(inputs), opts),
         {:ok, engines} <- Cache.lookup("engines", Cache.key(engines), opts) do
      policy = Baseline.policy(spec)

      if policy["mode"] == "fresh" or map_size(engines["services"]) == 0 do
        {:ok, Enum.uniq(project["images"] ++ engines["images"])}
      else
        baseline_inputs =
          Baseline.inputs(Map.put(project, "services", engines["services"]), policy)

        with {:ok, database} <- Cache.lookup("databases", Cache.key(baseline_inputs), opts) do
          {:ok, Enum.uniq(project["images"] ++ engines["images"] ++ database["images"])}
        end
      end
    else
      _ -> :missing
    end
  rescue
    Jason.DecodeError -> :missing
  end

  defp do_ensure(id, emit, opts) do
    spec = Inventory.spec(id)
    project = ensure_project(id, emit, opts)
    engines = ServiceImages.resolve(spec["services"] || %{}, opts)
    runtime = Map.put(project, "services", engines)
    run_id = Keyword.get(opts, :run_id, "preparation")
    runtime = Baseline.ensure(id, spec, runtime, run_id, emit, opts)
    runtime = Map.put(runtime, "fixture_hashes", Inventory.fixture_hashes(id))
    Store.write("runtimes/#{id}.json", runtime)
    Eab.Retention.retain(id, runtime)
    runtime
  end

  def ensure_project(id, emit, opts \\ []) do
    spec = Inventory.spec(id)
    inputs = build_inputs(id, spec)

    {project, status} =
      Cache.fetch(
        "projects",
        inputs,
        fn reason ->
          case reusable_project(inputs, opts) do
            nil ->
              emit.("Building #{id}: #{reason}")
              prepare(id, spec, inputs, emit)

            project ->
              emit.("Refreshing migration analysis for #{id}; reusing its exact prepared image")
              source = Store.path("scratch/migration-analysis-#{Cache.key(inputs)}")
              File.rm_rf!(source)
              File.mkdir_p!(source)

              try do
                provenance = Inventory.read_json(Inventory.case_path(id, "provenance.json"))

                receipt =
                  Source.snapshot(spec["repository"], source, emit,
                    expected_tree: provenance["broken_tree"]
                  )

                apply_environment(id, source)

                project
                |> Map.put("inputs", inputs)
                |> Map.put("source_receipt", receipt)
                |> Map.put("database_inputs", DatabaseSeed.describe(source, spec))
              after
                File.rm_rf!(source)
              end
          end
        end,
        opts
      )

    if status == :reused, do: emit.("Reusing prepared project for #{id}")
    project
  end

  # Scanner changes affect database compatibility, not the compiled application.
  # All other image inputs must match, including the source, environment patch,
  # runtime, Docker recipe and source-export implementation.
  def reusable_project(inputs, opts \\ []) do
    Cache.records("projects")
    |> Enum.find_value(fn record ->
      if Map.delete(record["inputs"], "database_scanner") ==
           Map.delete(inputs, "database_scanner") do
        case Cache.lookup("projects", record["id"], opts) do
          {:ok, project} -> project
          _ -> nil
        end
      end
    end)
  end

  def build_inputs(id, spec) do
    %{
      "version" => 2,
      "repository" => spec["repository"],
      "runtime" => Map.drop(spec["runtime"], ["before_test_commands"]),
      "recipe_hash" =>
        Inventory.hash(dockerfile(spec, spec["runtime"]["image"], spec["runtime"]["node_image"])),
      "seed_script" => Inventory.hash_file(BuildCache.script()),
      "database_scanner" => Inventory.hash_file(Inventory.path("lib/eab/database_seed.ex")),
      "source_export" => Inventory.hash_file(Inventory.path("lib/eab/source.ex")),
      "source_provenance" =>
        if(File.exists?(Inventory.case_path(id, "provenance.json")),
          do: Inventory.hash_file(Inventory.case_path(id, "provenance.json"))
        ),
      "patches" =>
        Map.new(["environment.patch"], fn file ->
          path = Inventory.case_path(id, file)
          {file, if(File.exists?(path), do: Inventory.hash_file(path), else: nil)}
        end)
    }
  end

  defp prepare(id, spec, inputs, emit) do
    dest = Store.path("build/projects/#{Cache.key(inputs)}")
    source = Path.join(dest, "source")
    File.rm_rf!(source)
    File.mkdir_p!(source)

    File.cp!(BuildCache.script(), Path.join(dest, "build_seed.exs"))
    Browser.copy_bundle(spec, dest)

    repo = spec["repository"]

    unless Regex.match?(~r/^[a-f0-9]{40}$/, repo["revision"]) and
             String.starts_with?(repo["url"], "https://github.com/"),
           do: raise("Unpinned repository")

    provenance = Inventory.read_json(Inventory.case_path(id, "provenance.json"))

    unless provenance["broken_revision"] == repo["revision"] and
             String.trim_trailing(repo["url"], ".git") == provenance["repository"],
           do: raise("Case source and provenance disagree")

    source_receipt = Source.snapshot(repo, source, emit, expected_tree: provenance["broken_tree"])

    apply_environment(id, source)

    previous = Enum.find(Cache.records("projects"), &(&1["id"] == Cache.key(inputs)))
    saved = if previous, do: previous["artifact"], else: %{}
    base = pin(saved["base_image"] || spec["runtime"]["image"])

    node =
      if spec["runtime"]["node_image"],
        do: pin(saved["node_image"] || spec["runtime"]["node_image"])

    File.write!(Path.join(dest, "Dockerfile"), dockerfile(spec, base, node))

    # Resolve the *installed* toolchain, not just its base image. Package updates
    # after Docker cache eviction must not inherit incompatible native objects.
    toolchain = build(dest, "elixir-agent-benchmark:toolchain-#{id}", "toolchain")
    toolchain_tag = BuildCache.tag(toolchain, "toolchain")
    key = BuildCache.key(spec, toolchain, node, inputs["recipe_hash"])
    seed = BuildCache.find(key)
    seed = if seed, do: Map.put(seed, "tag", BuildCache.tag(seed["image"], "seed"))

    if seed,
      do: emit.("Seeding #{id} from pristine build of #{seed["case"]} at #{seed["revision"]}"),
      else: emit.("No compatible build seed for #{id}; package download caches remain available")

    recipe = dockerfile(spec, base, node, toolchain: toolchain_tag, seed: seed && seed["tag"])
    File.write!(Path.join(dest, "Dockerfile"), recipe)
    tag = "elixir-agent-benchmark:project-#{Cache.key(inputs)}"
    image = build(dest, tag, "fixture")

    runtime = %{
      "image" => image,
      "source_receipt" => source_receipt,
      "images" => [image],
      "inputs" => inputs,
      "base_image" => base,
      "node_image" => node,
      "toolchain_image" => toolchain,
      "build_seed" => seed,
      "dockerfile" => recipe,
      "build_log" => Path.relative_to(Path.join(dest, "build.log"), Store.root()),
      "database_inputs" => DatabaseSeed.describe(source, spec)
    }

    BuildCache.publish(key, image, id, repo["revision"])
    runtime
  end

  defp apply_environment(id, source) do
    path = Inventory.case_path(id, "environment.patch")

    if File.regular?(path) and File.stat!(path).size > 0,
      do: Command.run!("git", ["apply", path], cd: source)
  end

  defp build(dest, tag, target) do
    result =
      Command.run(
        "docker",
        [
          "buildx",
          "build",
          "--load",
          "--provenance=false",
          "--progress=plain",
          "--target",
          target,
          "-t",
          tag,
          dest
        ],
        timeout: 3600,
        limit: 2_000_000
      )

    log = if target == "fixture", do: "build.log", else: "toolchain.log"
    File.write!(Path.join(dest, log), result["output"])
    if result["returncode"] != 0, do: raise("#{target} build failed: #{result["output"]}")

    Command.run!("docker", ["image", "inspect", tag, "--format", "{{.Id}}"], timeout: 30)
    |> String.trim()
  end

  def image_exists?(image),
    do: Command.run("docker", ["image", "inspect", image], timeout: 30)["returncode"] == 0

  defp pin(image) do
    Command.run!("docker", ["pull", "--quiet", image], timeout: 1200)
    [info] = Command.run!("docker", ["image", "inspect", image]) |> Jason.decode!()
    List.first(info["RepoDigests"] || []) || raise "Image has no immutable digest"
  end

  defp hex_install(image) do
    with [_, minor] <- Regex.run(~r{elixir:(\d+\.\d+)\.}, image || ""),
         {build, sha512} <- @hex_builds[minor] do
      "mix archive.install https://builds.hex.pm/installs/#{build}/hex-#{@hex_version}.ez " <>
        "--sha512 #{sha512} --force"
    else
      _ -> "mix local.hex #{@hex_version} --force"
    end
  end

  def dockerfile(spec, base, node \\ nil, opts \\ []) do
    runtime = spec["runtime"]

    env =
      Map.merge(
        %{
          "MIX_ENV" => "test",
          "MIX_HOME" => "/opt/mix",
          "HEX_HOME" => "/opt/hex",
          "ERL_FLAGS" => "+S 2:2"
        },
        runtime["environment"] || %{}
      )

    lines =
      if(node, do: ["FROM #{node} AS nodejs"], else: []) ++
        Browser.stages(spec) ++
        [
          "FROM #{base} AS toolchain",
          "USER root",
          "RUN if command -v apk; then apk add --no-cache git bash ca-certificates build-base brotli libstdc++ cmake grep ripgrep coreutils findutils diffutils; else apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git bash ca-certificates build-essential brotli cmake grep ripgrep coreutils findutils diffutils && rm -rf /var/lib/apt/lists/*; fi",
          "RUN if command -v useradd; then existing=$(getent passwd 1000 | cut -d: -f1); groupadd -f agent; if [ -n \"$existing\" ]; then usermod -l agent -d /home/agent -m -g agent \"$existing\"; else useradd -m -u 1000 -g agent agent; fi; else adduser -D -u 1000 agent; fi"
        ]

    lines =
      lines ++
        if(node,
          do: [
            "COPY --from=nodejs /usr/local/bin/node /usr/local/bin/node",
            "COPY --from=nodejs /usr/local/lib/node_modules /usr/local/lib/node_modules",
            "RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx"
          ],
          else: []
        )

    lines =
      lines ++
        Browser.install(spec) ++
        [
          "WORKDIR /workspace",
          "RUN mkdir -p /opt/mix /opt/hex /opt/eab-seed && chown agent:agent /workspace /opt/mix /opt/hex /opt/eab-seed",
          "USER agent"
        ] ++
        Enum.map(Enum.sort(env), fn {k, v} -> "ENV #{k}=#{Jason.encode!(v)}" end) ++
        ["RUN #{hex_install(runtime["image"])} && mix local.rebar --force"]

    lines =
      if opts[:toolchain] do
        Enum.take_while(lines, &(&1 != "FROM #{base} AS toolchain")) ++
          ["FROM #{opts[:toolchain]} AS toolchain"]
      else
        lines
      end

    lines =
      lines ++
        ["FROM toolchain AS prepared"] ++
        if(opts[:seed],
          do: [
            "COPY --from=#{opts[:seed]} --chown=agent:agent /workspace/ /workspace/",
            "COPY --from=#{opts[:seed]} --chown=agent:agent /opt/eab-seed/ /opt/eab-seed/"
          ],
          else: []
        ) ++
        [
          "COPY --chown=agent:agent build_seed.exs /opt/eab-build-seed.exs",
          "COPY --chown=agent:agent source/ /incoming/",
          ~s|RUN elixir -r /opt/eab-build-seed.exs -e 'Eab.FixtureSeed.sync("/incoming", "/workspace")'|,
          "RUN --mount=type=cache,id=eab-hex-packages-v1,target=/opt/hex/packages,sharing=locked,uid=1000,gid=1000 " <>
            "mix deps.get --only #{env["MIX_ENV"]}",
          "RUN elixir -r /opt/eab-build-seed.exs -S mix eab.seed",
          "RUN --mount=type=cache,id=eab-hex-packages-v1,target=/opt/hex/packages,sharing=locked,uid=1000,gid=1000 " <>
            "mix deps.get --only #{env["MIX_ENV"]} && mix deps.clean --unused",
          "RUN mix deps.loadpaths"
        ] ++
        if(runtime["profile"] == "plausible_ce",
          do: [
            "RUN --mount=type=cache,id=eab-npm-packages-v1,target=/opt/npm-cache,sharing=locked,uid=1000,gid=1000 npm ci --prefix tracker --cache /opt/npm-cache --no-audit --no-fund"
          ],
          else: []
        )

    Enum.join(
      lines ++
        Enum.map(
          setup_commands(runtime),
          &("RUN " <> &1)
        ) ++
        [
          "RUN rm -rf .git && git init && git config user.name Benchmark && git config user.email benchmark@localhost && git add . && git commit -m 'Initial task workspace'",
          "FROM toolchain AS fixture",
          "COPY --from=prepared --chown=agent:agent /workspace/ /workspace/",
          "COPY --from=prepared --chown=agent:agent /opt/eab-seed/ /opt/eab-seed/",
          "CMD [\"sleep\", \"infinity\"]"
        ],
      "\n"
    ) <> "\n"
  end

  defp setup_commands(runtime) do
    commands = runtime["setup_commands"] || ["mix deps.get", "mix deps.compile"]

    Enum.reject(
      commands,
      &(&1 in ["mix deps.get", "mix deps.get --only test", "mix deps.compile"])
    )
  end
end
