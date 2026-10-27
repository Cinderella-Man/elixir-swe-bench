defmodule Eab.Results do
  @moduledoc """
  Exports completed runs into public run series (ADR 0011) through a strict schema and
  builds the static results page. One public file holds one series of up to three runs.
  """
  alias Eab.{ModelIdentity, Results.Schema, Series}

  def root,
    do:
      Application.get_env(:eab, :results_page_root) ||
        Path.join(Application.get_env(:eab, :root, File.cwd!()), "results-page")

  def read!(path), do: path |> File.read!() |> Jason.decode!()
  def write!(path, value), do: File.write!(path, Jason.encode!(value, pretty: true) <> "\n")
  def validate!(record), do: Schema.validate!(record)

  def fixture_hashes(case_id, case_root \\ nil) do
    Schema.require!(
      is_binary(case_id) and Regex.match?(~r/^[A-Za-z0-9_-]+$/, case_id),
      "Invalid case ID"
    )

    dir = Path.join(case_root || Path.join(project_root(), "cases"), case_id)

    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.filter(&File.regular?(Path.join(dir, &1)))
    |> Map.new(&{&1, hash(File.read!(Path.join(dir, &1)))})
  end

  @doc "A public series record holding only this run, for a new series or to merge."
  def export!(run, opts \\ []) do
    require!(is_map(run), "Expected a run.json object")
    require!(run["status"] == "completed", "Only completed runs can be published")

    require!(
      run["validation"] != true or Series.admitted_validation?(run),
      "Validation runs decide which cases stay and are never published, unless a recorded decision admits them"
    )

    require!(
      is_nil(run["selection"]),
      "Selected-case repeats and error retries are not full-run results"
    )

    ids = run["cases"]
    inventory = get_in(run, ["protocol", "inventory"]) || %{}

    require!(
      is_list(ids) and ids != [] and ids == inventory["cases"],
      "Run cases must match the full frozen inventory, in order"
    )

    require!(Enum.uniq(ids) == ids, "Duplicate case IDs")

    for id <- ids do
      attempt = get_in(run, ["attempts", id]) || %{}

      require!(
        attempt["status"] == "completed" and is_boolean(get_in(attempt, ["grade", "passed"])),
        "#{id}: missing, interrupted or errored outcome cannot be scored"
      )
    end

    selected = opts[:inventory] || inventory
    selected_ids = selected["cases"]
    fixtures = get_in(run, ["protocol", "fixtures"]) || %{}

    require!(
      is_list(selected_ids) and Enum.all?(selected_ids, &(&1 in ids)),
      "The run has not evaluated every current case"
    )

    if opts[:inventory] do
      for id <- selected_ids do
        require!(
          fixtures[id] == fixture_hashes(id, opts[:case_root]),
          "#{id}: recorded fixtures differ from the current case"
        )
      end
    end

    claude_code = get_in(run, ["harness", "name"]) == "claude_code"

    require!(
      not claude_code or is_binary(get_in(run, ["harness", "claude_code_version"])),
      "The run has no recorded Claude Code version"
    )

    # The series is defined by the current cases only; retired cases are projected away.
    projected =
      run
      |> Map.put("cases", selected_ids)
      |> put_in(["protocol", "inventory"], Map.put(inventory, "id", selected["id"]))

    series = Series.id(projected)

    require!(
      is_nil(run["series"]) or run["series"] == series,
      "This run was started for run series #{String.slice(run["series"] || "", 0, 12)} but its setup no longer matches it"
    )

    model = run["model"] || %{}
    identity = ModelIdentity.details(model)
    quant = Keyword.get(opts, :quantization, identity["quantization"])

    file_size =
      Eab.Results.Resources.weight_size(run["memory"], identity["artifact"], model["backend"])

    size = Keyword.get(opts, :size_bytes, identity["size_bytes"] || file_size)

    resources =
      case Keyword.fetch(opts, :resources) do
        {:ok, value} -> value
        :error -> Eab.Results.Resources.from_run!(run["memory"])
      end

    settings = Map.delete(run["settings"] || %{}, "seed")
    seed = get_in(run, ["settings", "seed"])
    profile = model["profile"] || %{}

    record = %{
      "schema_version" => 5,
      "series_id" => series,
      "benchmark" => selected["id"],
      "model" => %{
        "name" => opts[:model_label] || identity["name"],
        "backend" => model["backend"],
        "quantization" => quant,
        "quantization_source" => source(opts, :quantization, quant),
        "size_bytes" => size,
        "size_source" =>
          cond do
            Keyword.has_key?(opts, :size_bytes) -> opts[:size_source] || "owner_supplied"
            identity["size_bytes"] -> "reported"
            file_size -> "artifact_files"
            true -> "not_reported"
          end,
        "parameter_count" => identity["parameter_count"]
      },
      "harness" => public_harness(run),
      "settings" => settings,
      "setup" => Series.public_setup(Series.setup(projected)),
      "case_fixtures" => Map.new(selected_ids, &{&1, fixtures[&1] || %{}}),
      "seeds" => if(is_integer(seed), do: Series.seeds()),
      "required_runs" => Series.required(),
      "runs" => [
        %{
          "run_id" => run["id"],
          "created_at" => run["created_at"],
          "seed" => seed,
          "source_release_id" => run["release_id"],
          "code_version" =>
            List.last(run["code_versions"] || [get_in(run, ["protocol", "implementation"])]),
          "deployment" => %{
            "server_build" => profile["build_info"],
            "total_slots" => profile["total_slots"],
            "parallel_attempts" => run["parallel_attempts"] || 1
          },
          "cases" =>
            Enum.map(selected_ids, fn id ->
              attempt = run["attempts"][id]

              %{
                "id" => id,
                "passed" => attempt["grade"]["passed"],
                "generated_tokens" => attempt["generated_tokens"],
                "model_calls" => attempt["calls"]
              }
            end),
          "resources" => resources
        }
      ],
      "evidence_url" => opts[:evidence_url],
      "note" => opts[:note] || ""
    }

    validate!(record)
  end

  defp public_harness(%{"harness" => %{"name" => "claude_code"} = harness}) do
    %{
      "name" => "claude_code",
      "version" => harness["claude_code_version"],
      "agent" => harness["agent"],
      "kit_sha256" => harness["kit_sha256"],
      "preamble_sha256" => harness["preamble_sha256"]
    }
  end

  defp public_harness(run) do
    agent = get_in(run, ["protocol", "agent"]) || %{}
    %{"name" => "pi", "version" => agent["version"] || "unknown"}
  end

  @doc "Adds one run to a series record, keeping each seed's first published run."
  def merge!(record, addition) do
    [run] = addition["runs"]

    require!(
      record["series_id"] == addition["series_id"],
      "The run belongs to another run series"
    )

    cond do
      Enum.any?(record["runs"], &(&1["run_id"] == run["run_id"])) ->
        record

      length(record["runs"]) >= record["required_runs"] ->
        raise ArgumentError, "Run series already has #{record["required_runs"]} runs"

      record["seeds"] && Enum.any?(record["runs"], &(&1["seed"] == run["seed"])) ->
        raise ArgumentError, "Seed #{run["seed"]} already has a run in this series"

      true ->
        runs = Enum.sort_by(record["runs"] ++ [run], & &1["created_at"])
        validate!(%{record | "runs" => runs})
    end
  end

  def load!(directory \\ Path.join(root(), "results")) do
    records =
      Path.wildcard(Path.join(directory, "*.json"))
      |> Enum.sort()
      |> Enum.map(fn path ->
        try do
          record = path |> read!() |> validate!()

          require!(
            Path.basename(path, ".json") == record["series_id"],
            "File name must be the series ID"
          )

          record
        rescue
          error -> raise ArgumentError, "#{Path.basename(path)}: #{Exception.message(error)}"
        end
      end)

    ids = for record <- records, run <- record["runs"], do: run["run_id"]
    require!(Enum.uniq(ids) == ids, "A run appears in more than one series")
    records
  end

  def series!(id, opts \\ []) do
    require!(is_binary(id) and Regex.match?(~r/^[a-f0-9]{64}$/, id), "Invalid series ID")
    path = Path.join([opts[:page_root] || root(), "results", id <> ".json"])
    require!(File.regular?(path), "Run series #{String.slice(id, 0, 12)} is not published")
    path |> read!() |> validate!()
  end

  def added?(id, opts \\ []) do
    is_binary(id) and Regex.match?(~r/^[A-Za-z0-9_-]+$/, id) and
      Enum.any?(
        Path.wildcard(Path.join([opts[:page_root] || root(), "results", "*.json"])),
        fn path ->
          case Jason.decode(File.read!(path)) do
            {:ok, %{"runs" => runs}} when is_list(runs) -> Enum.any?(runs, &(&1["run_id"] == id))
            _ -> false
          end
        end
      )
  end

  @doc "Adds a completed run to its series and rebuilds the page; repeats keep the record."
  def publish!(run, opts \\ []) do
    page = opts[:page_root] || root()

    # Serialize dashboard requests so two tabs cannot rebuild over each other's results.
    :global.trans({{__MODULE__, Path.expand(page)}, self()}, fn ->
      inventory = opts[:inventory] || Eab.Inventory.definition()
      opts = Keyword.merge(opts, page_root: page, inventory: inventory)
      addition = export!(run, opts)
      records = load!(Path.join(page, "results"))
      existing = Enum.find(records, &(&1["series_id"] == addition["series_id"]))
      record = if existing, do: merge!(existing, addition), else: addition
      status = if existing == record, do: :already_added, else: :added
      records = Enum.reject(records, &(&1["series_id"] == record["series_id"])) ++ [record]

      stage =
        Path.join(
          page,
          ".publish-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
        )

      destination = Path.join([page, "results", record["series_id"] <> ".json"])

      try do
        # Validate every record and generate every asset before changing the series.
        build!(records, stage, opts)
        mkdir_owned!(Path.join(page, "results"), page)
        mkdir_owned!(Path.join(page, "dist"), page)

        if status == :added do
          staged = Path.join(stage, "series.json")
          write!(staged, record)
          inherit_owner!(staged, page)
          File.rename!(staged, destination)
        end

        # Replace complete files, with HTML last so it references the new asset hashes.
        for name <- ~w(styles.css app.js results.js results.json .nojekyll index.html) do
          source = Path.join(stage, name)
          inherit_owner!(source, page)
          File.rename!(source, Path.join([page, "dist", name]))
        end

        status
      after
        File.rm_rf!(stage)
      end
    end)
  end

  def build!(records, destination \\ Path.join(root(), "dist"), opts \\ []) do
    page = opts[:page_root] || root()
    inventory = opts[:inventory] || Eab.Inventory.definition()
    expected = Map.new(inventory["cases"], &{&1, fixture_hashes(&1, opts[:case_root])})

    for record <- records do
      validate!(record)

      require!(
        record["benchmark"] == inventory["id"] and
          Enum.map(hd(record["runs"])["cases"], & &1["id"]) == inventory["cases"] and
          record["case_fixtures"] == expected,
        "#{record["series_id"]}: series does not match the current cases; start a new series"
      )
    end

    ids = Enum.map(records, & &1["series_id"])
    require!(Enum.uniq(ids) == ids, "Duplicate series ID")

    payload = %{
      "schema_version" => 5,
      "benchmark" => %{"id" => inventory["id"], "case_count" => length(inventory["cases"])},
      "results" => Enum.map(records, &aggregate/1)
    }

    repository =
      opts[:repository] ||
        System.get_env("GITHUB_REPOSITORY", "Cinderella-Man/elixir-agent-benchmark")

    require!(
      Regex.match?(~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/, repository),
      "Invalid repository name"
    )

    File.mkdir_p!(destination)

    html =
      File.read!(Path.join(page, "index.html"))
      |> String.replace("__REPOSITORY_URL__", "https://github.com/#{repository}")

    html =
      Enum.reduce(~w(styles.css app.js), html, fn name, html ->
        body = File.read!(Path.join(page, name))
        File.write!(Path.join(destination, name), body)
        version_asset(html, name, body)
      end)

    body = Jason.encode!(payload, pretty: true)
    File.write!(Path.join(destination, "index.html"), version_asset(html, "results.js", body))
    File.write!(Path.join(destination, "results.json"), body <> "\n")

    File.write!(
      Path.join(destination, "results.js"),
      "window.BENCHMARK_DATA = " <> String.replace(body, "<", "\\u003c") <> ";\n"
    )

    File.touch!(Path.join(destination, ".nojekyll"))
    destination
  end

  @doc "A series with its mean score, interval, per-case passes, missing seeds and peak memory."
  def aggregate(record) do
    summary = Series.summary(record["runs"])
    filled = Enum.map(record["runs"], & &1["seed"])

    Map.merge(record, %{
      "run_count" => summary["run_count"],
      "complete" => summary["complete"],
      "score_percent" => summary["score_percent"],
      "interval_percent" => summary["interval_percent"],
      "total" => length(hd(record["runs"])["cases"]),
      "case_passes" => summary["case_passes"],
      "missing_seeds" => if(record["seeds"], do: record["seeds"] -- filled, else: []),
      "resources" => Series.peak_resources(Enum.map(record["runs"], & &1["resources"]))
    })
  end

  defp version_asset(html, name, body),
    do: String.replace(html, ~s("#{name}"), ~s("#{name}?v=#{String.slice(hash(body), 0, 12)}"))

  defp source(opts, key, value),
    do:
      if(Keyword.has_key?(opts, key),
        do: "owner_supplied",
        else: if(is_nil(value), do: "not_reported", else: "reported")
      )

  defp hash(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  defp require!(condition, message), do: Schema.require!(condition, message)

  defp project_root, do: Application.get_env(:eab, :root, File.cwd!())

  defp mkdir_owned!(path, page) do
    unless File.dir?(path) do
      File.mkdir_p!(path)
      inherit_owner!(path, page)
    end
  end

  # The Docker release runs as root; keep bind-mounted outputs editable by the checkout owner.
  defp inherit_owner!(path, page) do
    %{uid: uid, gid: gid} = File.stat!(page)
    File.chown!(path, uid)
    File.chgrp!(path, gid)
  end
end
