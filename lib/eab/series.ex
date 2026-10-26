defmodule Eab.Series do
  @moduledoc """
  Run series (ADR 0011): up to three ordinary runs of one model artifact and quantization
  through one harness on one case set. Runs join when their setup matches; hardware,
  endpoint, model file path, server build, slot count, seed and benchmark code version
  may differ. Each seed counts once: the first run with a final score fills it.
  """
  alias Eab.{Cache, ModelIdentity, Runner}

  @seeds [101, 102, 103]
  @required 3
  # llama.cpp's default sampler parameters; other /props fields describe the deployment.
  @sampling ~w(temperature dynatemp_range dynatemp_exponent top_k top_p min_p top_n_sigma
    xtc_probability xtc_threshold typical_p repeat_last_n repeat_penalty presence_penalty
    frequency_penalty dry_multiplier dry_base dry_allowed_length dry_penalty_last_n
    dry_sequence_breakers mirostat mirostat_tau mirostat_eta samplers min_keep)
  @api_backends ~w(openai_subscription anthropic claude_code)

  def seeds, do: @seeds
  def required, do: @required

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
      "model" => %{
        "name" => identity["name"],
        "artifact" => artifact(identity["artifact"]),
        "quantization" => identity["quantization"],
        "api_model" => if(model["backend"] in @api_backends, do: model["model"])
      },
      "chat_template_sha256" =>
        if(is_binary(profile["chat_template"]), do: Eab.Inventory.hash(profile["chat_template"])),
      "sampling_defaults" =>
        Map.take(get_in(profile, ["default_generation_settings", "params"]) || %{}, @sampling),
      "settings" => Map.drop(run["settings"] || %{}, ~w(seed reasoning_effort_source))
    }
  end

  def id(run), do: Cache.key(setup(run))

  defp artifact(nil), do: nil

  defp artifact(name),
    do: name |> String.replace(~r/-\d{5}-of-\d{5}(?=\.gguf$)/i, "")

  defp harness(run) do
    case run["harness"] do
      %{"name" => "claude_code"} = harness ->
        Map.take(
          harness,
          ~w(name agent kit_sha256 preamble_sha256 tools_sha256 claude_code_version)
        )

      _ ->
        agent = get_in(run, ["protocol", "agent"]) || %{}
        %{"name" => "pi", "version" => agent["version"], "lock_sha256" => agent["lock_sha256"]}
    end
  end

  @doc "Runs that may join a series at all: full, unpublishable-free runs with a final score."
  def eligible?(run) do
    is_map(run) and run["validation"] != true and is_nil(run["selection"]) and
      is_binary(run["release_id"]) and is_number(Runner.score(run)["score_percent"])
  end

  def seeded?(run), do: is_integer(get_in(run, ["settings", "seed"]))

  @doc "The runs that count, oldest first: the first scored run per seed, or the first three."
  def counted(runs) do
    runs = runs |> Enum.filter(&eligible?/1) |> Enum.sort_by(& &1["created_at"])

    if Enum.any?(runs, &seeded?/1) do
      for seed <- @seeds,
          run = Enum.find(runs, &(get_in(&1, ["settings", "seed"]) == seed)),
          do: run
    else
      Enum.take(runs, @required)
    end
  end

  def missing_seeds(runs) do
    if runs != [] and Enum.all?(runs, &seeded?/1),
      do: @seeds -- Enum.map(runs, &get_in(&1, ["settings", "seed"])),
      else: []
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
        "runs" => Enum.map(counted, & &1["id"]),
        "missing_seeds" => missing_seeds(counted)
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
  Checks a run about to start as a contribution to a published series. Everything but the
  Claude Code version must match now; that version is checked at publication.
  """
  def contribution!(run, series_id) do
    record = Eab.Results.series!(series_id)

    expected =
      Map.merge(record["setup"], %{
        "benchmark" => record["benchmark"],
        "cases" => Enum.map(record["runs"] |> hd() |> Map.fetch!("cases"), & &1["id"]),
        "case_fixtures" => record["case_fixtures"]
      })

    actual = setup(run)

    differences =
      for field <- Enum.sort(Map.keys(expected)),
          strip(field, expected[field]) != strip(field, actual[field]),
          do: field

    if differences != [],
      do:
        raise(
          "This endpoint and these settings do not match run series #{String.slice(series_id, 0, 12)}: " <>
            Enum.map_join(differences, ", ", &String.replace(&1, "_", " ")) <> " differ"
        )

    filled = Enum.map(record["runs"], & &1["seed"])
    seed = get_in(run, ["settings", "seed"])

    cond do
      length(record["runs"]) >= @required ->
        raise "Run series #{String.slice(series_id, 0, 12)} already has #{@required} runs"

      record["seeds"] && seed not in (record["seeds"] -- filled) ->
        raise "Choose one of the series' missing seeds: #{Enum.join(record["seeds"] -- filled, ", ")}"

      true ->
        :ok
    end
  end

  defp strip("harness", harness) when is_map(harness),
    do: Map.delete(harness, "claude_code_version")

  defp strip(_, value), do: value

  @doc "The setup as published; the benchmark, cases and fixtures are top-level fields."
  def public_setup(setup), do: Map.drop(setup, ~w(cases case_fixtures benchmark))
end
