defmodule Eab.Results do
  @moduledoc """
  Exports completed runs into public run series (ADR 0011) through a strict schema and
  builds the static results page. One public file holds one series of up to three runs.
  `results/` holds the current benchmark release's series; `releases/<name>/` holds an
  earlier release's, kept as published. `releases.json` says which release the page shows first.
  """
  alias Eab.{
    ContextSize,
    ModelIdentity,
    Results.Machine,
    Results.Schema,
    Results.Speed,
    Results.Timing,
    Series
  }

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

  @doc "Whether a run is a speed run (ADR 0020): published on its own, never scored."
  def speed_run?(run), do: get_in(run, ["selection", "kind"]) == "speed"

  @doc "A public series record holding only this run, for a new series or to merge."
  def export!(run, opts \\ []) do
    require!(is_map(run), "Expected a run.json object")
    require!(run["status"] == "completed", "Only completed runs can be published")
    require!(not speed_run?(run), "A speed run is published on its own, not into a run series")

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
    graded!(run, ids)
    selected = opts[:inventory] || inventory
    selected_ids = selected["cases"]

    require!(
      is_list(selected_ids) and Enum.all?(selected_ids, &(&1 in ids)),
      "The run has not evaluated every current case"
    )

    current_fixtures!(run, selected_ids, opts)
    parts = public_parts!(run, selected, selected_ids, opts)
    series = Series.id(parts.projected)

    # A series published before hashes were recorded names none in its setup; a run started
    # for it still joins it, and merge!/2 compares the files when the series records them.
    series =
      if run["series"] && run["series"] != series &&
           Series.id(parts.projected, hashes: false) == run["series"],
         do: run["series"],
         else: series

    require!(
      is_nil(run["series"]) or run["series"] == series,
      "This run was started for run series #{String.slice(run["series"] || "", 0, 12)} but its setup no longer matches it"
    )

    record = %{
      "schema_version" => Schema.current_version(),
      "series_id" => series,
      "benchmark" => selected["id"],
      "model" => parts.model,
      "harness" => parts.harness,
      "settings" => parts.settings,
      "setup" => parts.setup,
      "case_fixtures" => parts.case_fixtures,
      "seeds" => if(is_integer(parts.run["seed"]), do: "any"),
      "required_runs" => Series.required(),
      "runs" => [parts.run],
      "evidence_url" => opts[:evidence_url],
      "note" => opts[:note] || ""
    }

    validate!(record)
  end

  @doc """
  The public record of a completed speed run (ADR 0020): its model, settings, machine and the
  speed cases with their times. `series_id` is the run series its setup belongs to.
  """
  def export_speed!(run, opts \\ []) do
    require!(is_map(run), "Expected a run.json object")
    require!(run["status"] == "completed", "Only completed runs can be published")
    require!(speed_run?(run), "Only a speed run is published as one")
    inventory = get_in(run, ["protocol", "inventory"]) || %{}
    selected = opts[:inventory] || inventory
    speed = opts[:speed_cases] || Eab.Inventory.speed_cases(selected)
    ids = run["cases"]
    require!(ids == speed, "The run's cases are not this benchmark's speed cases")

    require!(
      is_list(selected["cases"]) and
        Enum.all?(selected["cases"], &(&1 in (inventory["cases"] || []))),
      "The run was made for other cases than the current ones"
    )

    require!(
      (run["parallel_attempts"] || 1) == 1,
      "A speed run works on one case at a time"
    )

    graded!(run, ids)
    current_fixtures!(run, ids, opts)
    parts = public_parts!(run, selected, ids, opts)

    Speed.validate!(%{
      "schema_version" => Schema.current_version(),
      "kind" => "speed_run",
      "series_id" => Series.id(parts.projected),
      "benchmark" => selected["id"],
      "model" => parts.model,
      "harness" => parts.harness,
      "settings" => parts.settings,
      "setup" => parts.setup,
      "case_fixtures" => parts.case_fixtures,
      "run" => parts.run,
      "note" => opts[:note] || ""
    })
  end

  defp graded!(run, ids) do
    for id <- ids do
      attempt = get_in(run, ["attempts", id]) || %{}

      require!(
        attempt["status"] == "completed" and is_boolean(get_in(attempt, ["grade", "passed"])),
        "#{id}: missing, interrupted or errored outcome cannot be scored"
      )
    end
  end

  defp current_fixtures!(run, ids, opts) do
    fixtures = get_in(run, ["protocol", "fixtures"]) || %{}

    if opts[:inventory] do
      for id <- ids do
        require!(
          fixtures[id] == fixture_hashes(id, opts[:case_root]),
          "#{id}: recorded fixtures differ from the current case"
        )
      end
    end
  end

  # The public model, harness, settings and setup of a run, and the run itself with the
  # outcomes of `ids`. The setup is the series' over the current cases, `selected`.
  defp public_parts!(run, selected, ids, opts) do
    inventory = get_in(run, ["protocol", "inventory"]) || %{}
    fixtures = get_in(run, ["protocol", "fixtures"]) || %{}
    claude_code = get_in(run, ["harness", "name"]) == "claude_code"

    require!(
      not claude_code or is_binary(get_in(run, ["harness", "claude_code_version"])),
      "The run has no recorded Claude Code version"
    )

    # The series is defined by the current cases only; retired cases are projected away.
    projected =
      run
      |> Map.put("cases", selected["cases"])
      |> put_in(["protocol", "inventory"], Map.put(inventory, "id", selected["id"]))

    model = run["model"] || %{}
    identity = ModelIdentity.details(model)

    weights =
      Eab.Results.Resources.weight_files(
        run["memory"],
        ModelIdentity.served_artifact(model),
        model["backend"]
      )

    file_size = weights && weights["size_bytes"]
    # The bytes served, as the collector hashed them on the model host (ADR 0018).
    measured = Series.weights(run)
    # Strata reports only its pack folder; the collector names the GGUF files behind it.
    files = if is_nil(identity["artifact"]), do: ModelIdentity.from_files(weights)
    file_quant = files["quantization"]
    quant = Keyword.get(opts, :quantization, identity["quantization"] || file_quant)
    creator = Series.creator(run)

    require!(
      is_nil(opts[:quantized_by]) or is_nil(creator) or opts[:quantized_by] == creator,
      "The served file names its maker as #{creator}"
    )

    size = Keyword.get(opts, :size_bytes, identity["size_bytes"] || file_size)

    resources =
      case Keyword.fetch(opts, :resources) do
        {:ok, value} -> value
        :error -> Eab.Results.Resources.from_run!(run["memory"])
      end

    settings = Map.delete(run["settings"] || %{}, "seed")
    profile = model["profile"] || %{}
    # Times are comparable only when the run worked on one case at a time (ADRs 0014 and 0019).
    timed? = (run["parallel_attempts"] || 1) == 1 and not claude_code

    cases =
      Enum.map(ids, fn id ->
        attempt = run["attempts"][id]

        %{
          "id" => id,
          "passed" => attempt["grade"]["passed"],
          # The grader's verdict on the patch alone. Under a token allowance (ADR 0021) a
          # passing patch still fails its case when the agent did not finish inside it.
          "patch_passed" => Map.get(attempt["grade"], "patch_passed", attempt["grade"]["passed"]),
          "generated_tokens" => attempt["generated_tokens"],
          # The largest context any model call held; scores at smaller context sizes are
          # read from it (ADR 0022).
          "peak_context_tokens" => ContextSize.of_attempt(run["id"], id, attempt),
          "model_calls" => attempt["calls"],
          "cutoff" => cutoff(attempt, settings["max_tokens"], model["backend"]),
          "timing" => if(timed?, do: Timing.of_case(attempt))
        }
      end)

    %{
      projected: projected,
      model: %{
        "name" => opts[:model_label] || files["name"] || identity["name"],
        "backend" => model["backend"],
        "quantization" => quant,
        "quantization_source" =>
          cond do
            Keyword.has_key?(opts, :quantization) or identity["quantization"] ->
              source(opts, :quantization, quant)

            file_quant ->
              "artifact_files"

            true ->
              "not_reported"
          end,
        "size_bytes" => size,
        "size_source" =>
          cond do
            Keyword.has_key?(opts, :size_bytes) -> opts[:size_source] || "owner_supplied"
            identity["size_bytes"] -> "reported"
            file_size -> "artifact_files"
            true -> "not_reported"
          end,
        "parameter_count" => identity["parameter_count"],
        "quantized_by" => opts[:quantized_by] || creator,
        "quantized_by_source" =>
          cond do
            creator -> "artifact_files"
            opts[:quantized_by] -> "owner_supplied"
            true -> "not_reported"
          end,
        "source" => public_source(model, measured, opts),
        "weight_files" => measured,
        "gguf" => gguf(weights)
      },
      harness: public_harness(run),
      settings: settings,
      setup: Series.public_setup(Series.setup(projected)),
      case_fixtures: Map.new(ids, &{&1, fixtures[&1] || %{}}),
      run: %{
        "run_id" => run["id"],
        "created_at" => run["created_at"],
        "seed" => get_in(run, ["settings", "seed"]),
        "source_release_id" => run["release_id"],
        "code_version" =>
          List.last(run["code_versions"] || [get_in(run, ["protocol", "implementation"])]),
        "deployment" => %{
          "server_build" => Eab.Model.build(profile),
          "total_slots" => profile["total_slots"],
          "parallel_attempts" => run["parallel_attempts"] || 1
        },
        "cases" => cases,
        "timing" => Timing.of_run(cases),
        # Where the model ran: GPUs, CPU, RAM, server and its speed flags (ADR 0020).
        "machine" => Machine.from_run(run["memory"]),
        "resources" => resources
      }
    }
  end

  @doc """
  The budget that ended an attempt before the agent finished, or nil; the patch at that point
  was graded. Claude Code cannot enforce the generation budget, so it is never cut off by it.
  """
  def cutoff(attempt, max_tokens, backend) do
    case attempt["stop_reason"] do
      "token_budget" ->
        "generation_budget"

      reason when reason in ~w(context_budget context_limit) ->
        "context_budget"

      reason when reason in ~w(response_budget response_limit) ->
        "response_budget"

      # Pi runs recorded before 2026-11-13 saved a final reply cut at the remaining generation
      # budget as agent_completed. Local servers' replies are capped at that remainder, so
      # reaching the budget exactly means the last one was cut; elsewhere it is a soft threshold.
      _ ->
        tokens = attempt["generated_tokens"]

        if backend in ~w(llama_cpp strata maya) and is_integer(max_tokens) and is_integer(tokens) and
             tokens >= max_tokens,
           do: "generation_budget"
    end
  end

  # Where the files came from: as declared when the run started, or as the publisher gives it
  # with --source-url, checked against the measured hashes (ADR 0018).
  defp public_source(model, measured, opts) do
    source =
      case opts[:source_url] do
        nil ->
          model["source"]

        url ->
          case Eab.ModelSource.declare(url, nil, "publisher") do
            {:ok, source} -> source
            {:error, message} -> raise ArgumentError, message
          end
      end

    require!(
      is_nil(opts[:release_label]) or not is_nil(source),
      "A release label needs the model's source; add --source-url"
    )

    source =
      if opts[:release_label] && source,
        do: Map.put(source, "release_label", String.trim(opts[:release_label])),
        else: source

    source
    |> Eab.ModelSource.verify(measured, network: Keyword.get(opts, :network, true))
    |> Eab.ModelSource.public()
  end

  @doc false
  def gguf(nil), do: nil

  def gguf(weights) do
    case weights["gguf"] do
      %{} = metadata when map_size(metadata) > 0 -> metadata
      _ -> nil
    end
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

  @doc "Adds one run to a series record, up to its required runs, whatever their seeds."
  def merge!(record, addition) do
    [run] = addition["runs"]

    require!(
      record["series_id"] == addition["series_id"],
      "The run belongs to another run series"
    )

    recorded = record["model"]["weight_files"]
    served = addition["model"]["weight_files"]

    require!(
      is_nil(recorded) or is_nil(served) or
        Enum.map(recorded, & &1["sha256"]) == Enum.map(served, & &1["sha256"]),
      "The served weight files differ from the ones this run series was made with"
    )

    cond do
      Enum.any?(record["runs"], &(&1["run_id"] == run["run_id"])) ->
        record

      length(record["runs"]) >= record["required_runs"] ->
        raise ArgumentError, "Run series already has #{record["required_runs"]} runs"

      true ->
        record = upgrade(record)
        runs = Enum.sort_by(record["runs"] ++ [run], & &1["created_at"])
        validate!(%{record | "runs" => runs})
    end
  end

  # An older series takes the current schema when it takes another run. Its runs recorded
  # what they recorded: timing before schema 9, the machine before 10 and peak context before
  # 12 are null. Before schema 11 a case's outcome was its patch's verdict. Before schema 13
  # a seeded series took seeds 101, 102 and 103, once each; its runs keep theirs, and it now
  # takes a run with any seed, a repeated one too (ADR 0025).
  @doc false
  def upgrade(record) do
    runs =
      Enum.map(record["runs"], fn run ->
        cases =
          Enum.map(run["cases"], fn c ->
            c
            |> Map.put_new("timing", nil)
            |> Map.put_new("patch_passed", c["passed"])
            |> Map.put_new("peak_context_tokens", nil)
          end)

        run
        |> Map.put("cases", cases)
        |> Map.put_new("timing", nil)
        |> Map.put_new("machine", nil)
      end)

    seeds = if record["seeds"], do: "any"
    %{record | "schema_version" => Schema.current_version(), "runs" => runs, "seeds" => seeds}
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

  @doc """
  Earlier benchmark releases whose series stay on the page as they were published. Each
  folder under `releases/` holds one release's series files. Their cases have changed
  since, so they are checked against each other, never against the current cases, and
  they take no more runs.
  """
  def frozen!(page \\ root()) do
    Path.wildcard(Path.join([page, "releases", "*"]))
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort()
    |> Enum.map(fn directory ->
      name = Path.basename(directory)
      records = load!(directory)
      require!(records != [], "releases/#{name}: an earlier release needs at least one series")
      [first | _] = records
      cases = Enum.map(hd(first["runs"])["cases"], & &1["id"])

      require!(
        Enum.all?(records, fn record ->
          record["benchmark"] == first["benchmark"] and
            Enum.map(hd(record["runs"])["cases"], & &1["id"]) == cases and
            record["case_fixtures"] == first["case_fixtures"]
        end),
        "releases/#{name}: the series of one release must share its benchmark, cases and case files"
      )

      speed = Speed.load!(Path.join(directory, "speed"))

      speed_cases =
        speed |> Enum.map(&Enum.map(&1["run"]["cases"], fn c -> c["id"] end)) |> Enum.uniq()

      require!(
        Enum.all?(speed, &(&1["benchmark"] == first["benchmark"])) and length(speed_cases) <= 1,
        "releases/#{name}: its speed runs must share its benchmark and speed cases"
      )

      %{
        "id" => first["benchmark"],
        "case_count" => length(cases),
        "records" => records,
        "speed" => speed,
        "speed_cases" => List.first(speed_cases)
      }
    end)
  end

  @doc """
  The page's own settings, from `releases.json`: which release it shows first (`primary`,
  a benchmark ID) and a note per release. Without the file the current release is primary.
  """
  def page_settings(page \\ root()) do
    path = Path.join(page, "releases.json")
    settings = if File.regular?(path), do: read!(path), else: %{}

    require!(
      is_map(settings) and Map.keys(settings) -- ~w(primary notes) == [] and
        (is_nil(settings["primary"]) or is_binary(settings["primary"])) and
        (is_nil(settings["notes"]) or
           (is_map(settings["notes"]) and Enum.all?(Map.values(settings["notes"]), &is_binary/1))),
      "releases.json holds a primary benchmark ID and a note per benchmark ID"
    )

    settings
  end

  def series!(id, opts \\ []) do
    require!(is_binary(id) and Regex.match?(~r/^[a-f0-9]{64}$/, id), "Invalid series ID")
    path = Path.join([opts[:page_root] || root(), "results", id <> ".json"])
    require!(File.regular?(path), "Run series #{String.slice(id, 0, 12)} is not published")
    path |> read!() |> validate!()
  end

  def added?(id, opts \\ []) do
    page = opts[:page_root] || root()

    is_binary(id) and Regex.match?(~r/^[A-Za-z0-9_-]+$/, id) and
      (File.regular?(Path.join([page, "speed", id <> ".json"])) or
         Path.wildcard(Path.join([page, "releases", "*", "speed", id <> ".json"])) != [] or
         added_to_series?(id, opts))
  end

  defp added_to_series?(id, opts) do
    Enum.any?(
      Path.wildcard(Path.join([opts[:page_root] || root(), "results", "*.json"])) ++
        Path.wildcard(Path.join([opts[:page_root] || root(), "releases", "*", "*.json"])),
      fn path ->
        case Jason.decode(File.read!(path)) do
          {:ok, %{"runs" => runs}} when is_list(runs) -> Enum.any?(runs, &(&1["run_id"] == id))
          _ -> false
        end
      end
    )
  end

  @doc """
  Adds a completed run to its series, or a speed run to the speed runs (ADR 0020), and rebuilds
  the page; repeats keep the published record.
  """
  def publish!(run, opts \\ []) do
    page = opts[:page_root] || root()

    # Serialize dashboard requests so two tabs cannot rebuild over each other's results.
    :global.trans({{__MODULE__, Path.expand(page)}, self()}, fn ->
      inventory = opts[:inventory] || Eab.Inventory.definition()
      opts = Keyword.merge(opts, page_root: page, inventory: inventory)
      records = load!(Path.join(page, "results"))
      speed = Speed.load!(Path.join(page, "speed"))

      {status, file, record, records, speed} =
        if speed_run?(run) do
          addition = export_speed!(run, opts)
          id = addition["run"]["run_id"]

          if Enum.any?(speed, &(&1["run"]["run_id"] == id)),
            do: {:already_added, nil, nil, records, speed},
            else:
              {:added, Path.join("speed", id <> ".json"), addition, records, speed ++ [addition]}
        else
          addition = export!(run, opts)
          existing = Enum.find(records, &(&1["series_id"] == addition["series_id"]))
          if is_nil(existing), do: unmeasured!(addition, records)
          record = if existing, do: merge!(existing, addition), else: addition
          status = if existing == record, do: :already_added, else: :added
          records = Enum.reject(records, &(&1["series_id"] == record["series_id"])) ++ [record]
          {status, Path.join("results", record["series_id"] <> ".json"), record, records, speed}
        end

      stage =
        Path.join(
          page,
          ".publish-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
        )

      try do
        # Validate every record and generate every asset before changing the series.
        build!(records, stage, Keyword.put(opts, :speed, speed))
        mkdir_owned!(Path.join(page, "dist"), page)

        if status == :added do
          mkdir_owned!(Path.join(page, Path.dirname(file)), page)
          staged = Path.join(stage, "record.json")
          write!(staged, record)
          inherit_owner!(staged, page)
          File.rename!(staged, Path.join(page, file))
        end

        # Replace complete files, with HTML last so it references the new asset hashes.
        for name <- ~w(styles.css theme.js app.js results.js results.json .nojekyll index.html) do
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

  # Only the memory collector reads the served files' hashes and maker on the model host
  # (ADR 0018). A run made without them whose setup otherwise matches a published series
  # that records them would start a second series of the same model.
  defp unmeasured!(addition, records) do
    model = addition["setup"]["model"]
    missing = Enum.reject(~w(sha256 quantized_by), &Map.has_key?(model, &1))
    alike = &(comparable(&1, missing) == comparable(addition, []))
    record = if missing != [], do: Enum.find(records, alike)

    if record do
      lacking = Map.take(record["setup"]["model"], missing)

      raise ArgumentError,
            "The model files' #{Series.measured_words(lacking)} were not read on the model " <>
              "host during this run, so it cannot join run series " <>
              "#{String.slice(record["series_id"], 0, 12)} (#{record["model"]["name"]}), " <>
              "whose setup it otherwise matches. Added on its own it would show that model " <>
              "twice. Make this model's runs from a controller whose memory collector " <>
              "reaches its model host."
    end
  end

  defp comparable(record, drop) do
    record
    |> Map.take(~w(benchmark setup case_fixtures))
    |> update_in(["setup", "model"], &Map.drop(&1, drop))
    |> Map.put("cases", Enum.map(hd(record["runs"])["cases"], & &1["id"]))
  end

  @doc """
  Cases without the summary page the results page links each case name to. It lives in
  docs/cases/, outside the case folder, so writing it changes no case fixture.
  """
  def missing_case_pages(cases),
    do: Enum.reject(cases, &File.regular?(Eab.Inventory.path("docs/cases/#{&1}.md")))

  def build!(records, destination \\ Path.join(root(), "dist"), opts \\ []) do
    page = opts[:page_root] || root()
    inventory = opts[:inventory] || Eab.Inventory.definition()
    expected = Map.new(inventory["cases"], &{&1, fixture_hashes(&1, opts[:case_root])})
    missing = missing_case_pages(inventory["cases"])

    require!(
      missing == [],
      "Write a summary page in docs/cases/ for: #{Enum.join(missing, ", ")}"
    )

    for record <- records do
      validate!(record)

      require!(
        record["benchmark"] == inventory["id"] and
          Enum.map(hd(record["runs"])["cases"], & &1["id"]) == inventory["cases"] and
          record["case_fixtures"] == expected,
        "#{record["series_id"]}: series does not match the current cases; start a new series"
      )

      # A series belongs to the release whose token allowances it was made under (ADR 0021).
      require!(
        record["setup"]["allowance"] == Eab.Allowance.table(inventory, inventory["cases"]),
        "#{record["series_id"]}: series was made under other token allowances; start a new series"
      )
    end

    ids = Enum.map(records, & &1["series_id"])
    require!(Enum.uniq(ids) == ids, "Duplicate series ID")

    # Speed runs of the current release, on its speed cases (ADR 0020).
    speed = opts[:speed] || Speed.load!(Path.join(page, "speed"))
    speed_cases = current_speed_cases(inventory, opts)

    for record <- speed do
      Speed.validate!(record)
      cases = Enum.map(record["run"]["cases"], & &1["id"])

      require!(
        record["benchmark"] == inventory["id"] and cases == speed_cases and
          record["case_fixtures"] == Map.take(expected, cases),
        "Speed run #{record["run"]["run_id"]} does not match the current speed cases"
      )
    end

    # Earlier releases stay on the page beside the current one, which takes the new runs.
    frozen = frozen!(page)
    settings = page_settings(page)
    notes = settings["notes"] || %{}

    releases =
      Enum.map(frozen, fn f ->
        release(
          f["id"],
          f["case_count"],
          f["records"],
          false,
          notes,
          f["speed"],
          f["speed_cases"]
        )
      end) ++
        [
          release(
            inventory["id"],
            length(inventory["cases"]),
            records,
            true,
            notes,
            speed,
            speed_cases
          )
        ]

    release_ids = Enum.map(releases, & &1["benchmark"]["id"])

    require!(
      Enum.uniq(release_ids) == release_ids,
      "An earlier release has the current benchmark's ID; its series belong in results/"
    )

    runs =
      for(
        release <- releases,
        series <- release["results"],
        run <- series["runs"],
        do: run["run_id"]
      ) ++
        for release <- releases, record <- release["speed_runs"], do: record["run"]["run_id"]

    require!(Enum.uniq(runs) == runs, "A run appears in more than one release")
    primary = settings["primary"] || inventory["id"]

    require!(
      primary in release_ids,
      "releases.json names #{primary} as primary, which is not a release on this page"
    )

    payload = %{
      "schema_version" => Schema.current_version(),
      "primary" => primary,
      "releases" => releases
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
      Enum.reduce(~w(styles.css theme.js app.js), html, fn name, html ->
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

  # One release as the page shows it. Its label is the ID's last part, such as "v6".
  defp release(id, case_count, records, current?, notes, speed, speed_cases) do
    %{
      "benchmark" => %{"id" => id, "case_count" => case_count},
      "label" => id |> String.split("-") |> List.last(),
      "current" => current?,
      "note" => notes[id],
      # The context sizes a series' score can be shown at (ADR 0022).
      "context_sizes" => ContextSize.sizes(),
      "results" => Enum.map(records, &aggregate/1),
      "speed_cases" => speed_cases,
      "speed_runs" => speed
    }
  end

  # The current speed cases. A benchmark whose speed cases are not named yet has none; its
  # full runs still publish, but no speed run can.
  defp current_speed_cases(inventory, opts) do
    opts[:speed_cases] ||
      try do
        Eab.Inventory.speed_cases(inventory)
      rescue
        _ in [ArgumentError, File.Error] -> nil
      end
  end

  @doc "A series with its mean score, interval, per-case passes and peak memory."
  def aggregate(record) do
    summary = Series.summary(record["runs"])

    Map.merge(record, %{
      "run_count" => summary["run_count"],
      "complete" => summary["complete"],
      "score_percent" => summary["score_percent"],
      "interval_percent" => summary["interval_percent"],
      "total" => length(hd(record["runs"])["cases"]),
      "case_passes" => summary["case_passes"],
      "resources" => Series.peak_resources(Enum.map(record["runs"], & &1["resources"])),
      # The score at each context size, for series whose attempts recorded their peak context.
      "by_context" => ContextSize.scores(record)
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
