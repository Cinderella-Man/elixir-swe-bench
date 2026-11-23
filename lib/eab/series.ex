defmodule Eab.Series do
  @moduledoc """
  Run series (ADR 0011): up to three ordinary runs of one model artifact and quantization
  through one harness on one case set. Runs join when their setup matches; hardware,
  endpoint, model file path, server build, slot count, seed, benchmark code version and
  Claude Code program version may differ. Each run of a model server draws its own random
  seed (ADR 0025). A seed does not make a run repeat, so a series takes its first three runs
  with final scores whatever their seeds. Series published before then took seeds 101, 102
  and 103 once each, and keep those runs.
  """
  alias Eab.{Cache, Inventory, ModelIdentity, Runner}

  @required 3
  # Model servers take a seed of at most 31 bits (Model.settings), so ten digits at most.
  @seed_max 2_147_483_647
  # llama.cpp's default sampler parameters; other /props fields describe the deployment.
  @sampling ~w(temperature dynatemp_range dynatemp_exponent top_k top_p min_p top_n_sigma
    xtc_probability xtc_threshold typical_p repeat_last_n repeat_penalty presence_penalty
    frequency_penalty dry_multiplier dry_base dry_allowed_length dry_penalty_last_n
    dry_sequence_breakers mirostat mirostat_tau mirostat_eta samplers min_keep)
  @api_backends ~w(openai_subscription anthropic claude_code)

  def required, do: @required

  @doc """
  A random seed for a run, none of `taken`, so runs started on different machines record
  different seeds (ADR 0025).
  """
  def random_seed(taken \\ []) do
    <<n::32>> = :crypto.strong_rand_bytes(4)
    seed = rem(n, @seed_max) + 1
    if seed in taken, do: random_seed(taken), else: seed
  end

  @doc "Everything that must match for a run to join a series."
  def setup(run) do
    model = run["model"] || %{}
    identity = ModelIdentity.details(model)
    profile = model["profile"] || %{}
    protocol = run["protocol"] || %{}
    cases = run["cases"] || []

    %{
      "benchmark" => get_in(protocol, ["inventory", "id"]),
      "cases" => cases,
      "case_fixtures" => Map.take(protocol["fixtures"] || %{}, cases),
      "harness" => harness(run),
      "server_type" => model["backend"],
      "model" =>
        %{
          "name" => identity["name"],
          "artifact" => artifact(identity["artifact"]),
          "quantization" => identity["quantization"],
          "api_model" => if(model["backend"] in @api_backends, do: model["model"])
        }
        |> put_creator(creator(run))
        |> put_hashes(weights(run)),
      "chat_template_sha256" =>
        if(is_binary(profile["chat_template"]), do: Eab.Inventory.hash(profile["chat_template"])),
      "sampling_defaults" =>
        Map.take(get_in(profile, ["default_generation_settings", "params"]) || %{}, @sampling),
      "settings" => Map.drop(run["settings"] || %{}, ~w(seed reasoning_effort_source))
    }
    |> put_allowance(Eab.Allowance.table(protocol["inventory"], cases))
  end

  # Runs made under different token allowances never join (ADR 0021). Series of a release
  # without allowances keep their IDs.
  defp put_allowance(setup, nil), do: setup
  defp put_allowance(setup, allowance), do: Map.put(setup, "allowance", allowance)

  def id(run, opts \\ [])

  def id(run, hashes: false),
    do: Cache.key(update_in(setup(run), ["model"], &Map.delete(&1, "sha256")))

  def id(run, _), do: Cache.key(setup(run))

  @doc """
  Who made the served quantization, as its GGUF names itself; the memory collector reads it
  on the model host. Identically named files from different makers stay separate series.
  """
  def creator(run) do
    model = run["model"] || %{}

    files =
      Eab.Results.Resources.weight_files(
        run["memory"],
        ModelIdentity.served_artifact(model),
        model["backend"]
      )

    files && files["quantized_by"]
  end

  # Only a known maker joins the identity, so series whose files name no one keep their IDs.
  defp put_creator(model, nil), do: model
  defp put_creator(model, creator), do: Map.put(model, "quantized_by", creator)

  @doc """
  The served weight files with the sha256 the collector measured on the model host, in shard
  order, or nil when they were not hashed. Every session that hashed them must agree.
  """
  def weights(run) do
    model = run["model"] || %{}
    artifact = ModelIdentity.served_artifact(model)

    hashed =
      for session <- get_in(run, ["memory", "sessions"]) || [],
          identity = session["identity"] || %{},
          identity["model_artifact"] == artifact and identity["backend"] == model["backend"],
          %{"status" => "hashed", "files" => files} <- [session["weight_hashes"]],
          do: files

    case Enum.uniq(hashed) do
      [files] -> files
      _ -> nil
    end
  end

  # The bytes served join the identity (ADR 0018): a maker's re-upload under the same name is
  # another model. Series made before hashes were recorded keep their IDs.
  defp put_hashes(model, nil), do: model
  defp put_hashes(model, files), do: Map.put(model, "sha256", Enum.map(files, & &1["sha256"]))

  @doc "An artifact's name without its shard number, as a series records it."
  def artifact(nil), do: nil

  def artifact(name),
    do: name |> String.replace(~r/-\d{5}-of-\d{5}(?=\.gguf$)/i, "")

  defp harness(run) do
    case run["harness"] do
      # The desktop app updates Claude Code itself; each run records its version.
      %{"name" => "claude_code"} = harness ->
        Map.take(harness, ~w(name agent kit_sha256 preamble_sha256 tools_sha256))

      _ ->
        agent = get_in(run, ["protocol", "agent"]) || %{}
        %{"name" => "pi", "version" => agent["version"], "lock_sha256" => agent["lock_sha256"]}
    end
  end

  @doc "Runs that may join a series at all: full, unpublishable-free runs with a final score."
  def eligible?(run) do
    is_map(run) and (run["validation"] != true or admitted_validation?(run)) and
      is_nil(run["selection"]) and is_binary(run["release_id"]) and
      is_number(Runner.score(run)["score_percent"])
  end

  @doc """
  A validation run that a recorded decision admits, by run and release: its outcome could
  not change the release, so it counts like an ordinary run (ADR 0012).
  """
  def admitted_validation?(run) do
    is_map(run) and run["validation"] == true and
      Enum.any?(
        admitted_validation_runs(),
        &(&1["run_id"] == run["id"] and &1["release_id"] == run["release_id"])
      )
  end

  def admitted_validation_runs do
    Application.get_env(:eab, :admitted_validation_runs) ||
      Inventory.read_json(Inventory.path("priv/admitted_validation_runs.json"))["runs"]
  end

  def seeded?(run), do: is_integer(get_in(run, ["settings", "seed"]))

  @doc "The runs that count, oldest first: the first three scored runs, whatever their seeds."
  def counted(runs) do
    runs
    |> Enum.filter(&eligible?/1)
    |> Enum.sort_by(& &1["created_at"])
    |> Enum.take(@required)
  end

  @doc "Groups local runs into series and summarizes each (dashboard view)."
  def group(runs) do
    runs
    |> Enum.filter(&eligible?/1)
    |> Enum.group_by(&id/1)
    |> Enum.map(fn {id, members} ->
      counted = counted(members)

      Map.merge(summary(Enum.map(counted, &outcomes/1)), %{
        "id" => id,
        "setup" => setup(hd(counted)),
        "runs" => Enum.map(counted, & &1["id"])
      })
    end)
    |> Enum.sort_by(&{-&1["score_percent"], &1["id"]})
  end

  @doc "Per-run case outcomes as `%{\"cases\" => [%{\"id\", \"passed\"}]}`."
  def outcomes(run) do
    %{
      "cases" =>
        Enum.map(run["cases"], fn id ->
          %{"id" => id, "passed" => get_in(run, ["attempts", id, "grade", "passed"]) == true}
        end)
    }
  end

  @doc """
  Mean score and rerun interval for runs given as case outcome lists. The interval is
  ±1.96·SE with SE = sqrt(Σ pᵢ(1−pᵢ)/(k−1)) / n over n cases and k runs, as the
  Terminal-Bench leaderboard computes it; it needs at least two runs.
  """
  def summary(runs) do
    k = length(runs)
    ids = runs |> List.first(%{"cases" => []}) |> Map.fetch!("cases") |> Enum.map(& &1["id"])
    n = length(ids)

    passes =
      Map.new(ids, fn id ->
        {id,
         Enum.count(runs, fn run ->
           Enum.any?(run["cases"], &(&1["id"] == id and &1["passed"]))
         end)}
      end)

    scores =
      Enum.map(runs, fn run -> 100 * Enum.count(run["cases"], & &1["passed"]) / max(n, 1) end)

    interval =
      if k >= 2 and n > 0 do
        variance =
          Enum.reduce(ids, 0, fn id, sum ->
            p = passes[id] / k
            sum + p * (1 - p) / (k - 1)
          end)

        Float.round(1.96 * :math.sqrt(variance) / n * 100, 2)
      end

    %{
      "run_count" => k,
      "required_runs" => @required,
      "complete" => k >= @required,
      "score_percent" => if(k > 0, do: Float.round(Enum.sum(scores) / k, 2), else: 0.0),
      "interval_percent" => interval,
      "case_passes" => passes
    }
  end

  @doc "The resource record with the highest RAM + VRAM peak across a series' runs."
  def peak_resources(resources) do
    resources
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&combined/1, fn -> nil end)
  end

  defp combined(%{"peak_combined_bytes" => bytes}) when is_integer(bytes), do: bytes

  defp combined(resource) do
    vram =
      resource["peak_vram_bytes"] ||
        Enum.reduce(resource["gpus"] || [], 0, &((&1["used_bytes"] || 0) + &2))

    vram + (resource["service_ram_bytes"] || resource["ram_rss_bytes"] || 0)
  end

  @doc """
  Why a published series can take no more runs although it lacks seeds, or nil. New local
  runs cap neither a single reply (ADR 0015) nor an attempt's generated tokens (ADR 0016),
  so no new run can match a series that did.
  """
  def closed_reason(%{
        "setup" => %{"server_type" => type, "settings" => %{"response_tokens" => cap}}
      })
      when type in ~w(llama_cpp strata maya) and is_integer(cap),
      do:
        "It was made with a #{cap}-token cap on each reply, which new runs no longer have " <>
          "(ADR 0015). A run of this model starts a new series."

  def closed_reason(%{
        "setup" => %{"server_type" => type, "settings" => %{"max_tokens" => budget}}
      })
      when type in ~w(llama_cpp strata maya) and is_integer(budget),
      do:
        "It was made with a #{budget}-token generation budget, which new local runs no longer " <>
          "have (ADR 0016). A run of this model starts a new series."

  def closed_reason(_), do: nil

  @doc "Checks a run about to start as a contribution to a published series."
  def contribution!(run, series_id) do
    record = Eab.Results.series!(series_id)

    if reason = closed_reason(record),
      do: raise("Run series #{String.slice(series_id, 0, 12)} takes no more runs. " <> reason)

    differences = differences(record, run)

    if differences != [],
      do:
        raise(
          "This endpoint and these settings do not match run series #{String.slice(series_id, 0, 12)}: " <>
            Enum.map_join(differences, ", ", &String.replace(&1, "_", " ")) <> " differ"
        )

    if length(record["runs"]) >= @required,
      do: raise("Run series #{String.slice(series_id, 0, 12)} already has #{@required} runs")

    :ok
  end

  # The setup fields in which a run about to start differs from a published series. The run
  # has no memory yet, so its files' maker and hashes are still unread and are taken as the
  # series'; export compares the whole setup again once the collector has read them.
  defp differences(record, run) do
    expected =
      Map.merge(record["setup"], %{
        "benchmark" => record["benchmark"],
        "cases" => Enum.map(record["runs"] |> hd() |> Map.fetch!("cases"), & &1["id"]),
        "case_fixtures" => record["case_fixtures"]
      })

    actual =
      Enum.reduce(~w(quantized_by sha256), setup(run), fn key, actual ->
        case {expected["model"], actual["model"]} do
          {%{^key => value}, model} when not is_map_key(model, key) ->
            put_in(actual, ["model", key], value)

          _ ->
            actual
        end
      end)

    for field <- Enum.sort(Map.keys(expected)),
        expected[field] != actual[field],
        do: field
  end

  @doc false
  def measured_words(fields) do
    case {Map.has_key?(fields, "sha256"), Map.has_key?(fields, "quantized_by")} do
      {true, true} -> "hashes and maker"
      {true, false} -> "hashes"
      {false, true} -> "maker"
    end
  end

  @doc "The setup as published; the benchmark, cases and fixtures are top-level fields."
  def public_setup(setup), do: Map.drop(setup, ~w(cases case_fixtures benchmark))
end
