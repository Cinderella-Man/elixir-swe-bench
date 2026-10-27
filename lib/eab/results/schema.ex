defmodule Eab.Results.Schema do
  @moduledoc false
  @fields ~w(schema_version series_id benchmark model harness settings setup case_fixtures seeds required_runs runs evidence_url note)
  @run_fields ~w(run_id created_at seed source_release_id code_version deployment cases resources)
  @model_fields ~w(name backend quantization quantization_source size_bytes size_source parameter_count)
  @nullable_int ~w(window_tokens response_tokens)
  @integer ~w(safety_tokens max_tokens)
  @text ~w(budget_policy context_policy reasoning_effort reasoning_effort_source thinking_policy)
  @thinking %{
    "server_preset" => ~w(server_reported operator_declared not_reported),
    "provider_request" => ~w(provider_request),
    "harness_agent_file" => ~w(harness_agent_file)
  }

  def validate!(r) do
    fields!(r, @fields, "Expected a public v5 run series; export the original run.json with add")
    require!(r["schema_version"] === 5, "Unsupported result schema")
    hex!(r["series_id"], "A series ID is required")
    text!(r["benchmark"], "benchmark")

    model = r["model"]
    fields!(model, @model_fields, "Unexpected model fields")
    for key <- ~w(name backend), do: text!(model[key], key)

    require!(
      model["quantization_source"] in ~w(reported owner_supplied not_reported),
      "Invalid quantization source"
    )

    if model["quantization_source"] == "not_reported",
      do: require!(is_nil(model["quantization"]), "Unreported quantization must be null"),
      else: text!(model["quantization"], "quantization")

    for key <- ~w(size_bytes parameter_count),
        do:
          require!(
            is_nil(model[key]) or positive?(model[key]),
            "#{key} must be a positive integer or null"
          )

    require!(
      model["size_source"] in ~w(reported artifact_files owner_supplied not_reported),
      "Invalid size source"
    )

    require!(
      is_nil(model["size_bytes"]) == (model["size_source"] == "not_reported"),
      "Size and its source must agree"
    )

    harness!(r["harness"])

    settings = r["settings"]
    require!(is_map(settings) and map_size(settings) > 0, "Effective settings are required")

    Enum.each(settings, fn {key, value} ->
      valid =
        cond do
          key in @nullable_int -> is_nil(value) or is_integer(value)
          key in @integer -> is_integer(value)
          key in @text -> is_binary(value)
          key == "compaction" -> is_boolean(value)
          true -> false
        end

      require!(valid, "Invalid or unknown setting: #{key}")
    end)

    if Map.has_key?(settings, "thinking_policy") do
      sources = @thinking[settings["thinking_policy"]]
      require!(is_list(sources), "Invalid thinking policy")
      text!(settings["reasoning_effort"], "reasoning_effort")
      require!(settings["reasoning_effort_source"] in sources, "Invalid thinking source")

      if settings["reasoning_effort_source"] == "not_reported",
        do:
          require!(
            settings["reasoning_effort"] == "unknown",
            "Unreported thinking must be unknown"
          )
    end

    require!(is_map(r["setup"]) and map_size(r["setup"]) > 0, "The series setup is required")
    require!(r["required_runs"] === 3, "A run series has three runs")

    require!(
      is_nil(r["seeds"]) or r["seeds"] == [101, 102, 103],
      "Local series use seeds 101, 102 and 103"
    )

    runs = r["runs"]
    require!(is_list(runs) and length(runs) in 1..3, "A series holds one to three runs")
    ids = Enum.map(hd(runs)["cases"] || [], & &1["id"])
    require!(ids != [] and Enum.uniq(ids) == ids, "Invalid or duplicated case IDs")

    for run <- runs do
      fields!(run, @run_fields, "Unexpected run fields")

      require!(
        Regex.match?(~r/^[A-Za-z0-9_-]+$/, text!(run["run_id"], "run_id")),
        "Invalid run ID"
      )

      date!(run["created_at"])
      hex!(run["source_release_id"], "A frozen source release ID is required")
      require!(is_nil(run["code_version"]) or hex?(run["code_version"]), "Invalid code version")

      if r["seeds"],
        do: require!(run["seed"] in r["seeds"], "Each run needs one of the series seeds"),
        else: require!(is_nil(run["seed"]), "This series records no seed")

      # Runs published before ADR 0014 ran one attempt at a time and record no value.
      fields!(
        Map.delete(run["deployment"] || %{}, "parallel_attempts"),
        ~w(server_build total_slots),
        "Unexpected deployment fields"
      )

      require!(
        is_nil(run["deployment"]["parallel_attempts"]) or
          run["deployment"]["parallel_attempts"] in 1..8,
        "Invalid parallel attempts"
      )

      require!(
        is_nil(run["deployment"]["server_build"]) or is_binary(run["deployment"]["server_build"]),
        "Invalid server build"
      )

      require!(
        is_nil(run["deployment"]["total_slots"]) or positive?(run["deployment"]["total_slots"]),
        "Invalid slot count"
      )

      require!(is_list(run["cases"]), "Missing case outcomes")
      require!(Enum.map(run["cases"], & &1["id"]) == ids, "Every run must list the same cases")

      for c <- run["cases"] do
        fields!(c, ~w(id passed generated_tokens model_calls), "Unexpected case fields")
        require!(is_boolean(c["passed"]), "Every case needs a final pass/fail outcome")

        for key <- ~w(generated_tokens model_calls),
            do:
              require!(
                is_nil(c[key]) or nonnegative?(c[key]),
                "#{key} must be a nonnegative integer or null"
              )
      end

      if not is_nil(run["resources"]),
        do: Eab.Results.Resources.validate!(run["resources"], model, settings)
    end

    run_ids = Enum.map(runs, & &1["run_id"])
    require!(Enum.uniq(run_ids) == run_ids, "Duplicate run IDs")
    seeds = Enum.map(runs, & &1["seed"])
    require!(is_nil(r["seeds"]) or Enum.uniq(seeds) == seeds, "Each seed counts once")
    require!(Enum.sort_by(runs, & &1["created_at"]) == runs, "Runs are listed oldest first")

    fields!(r["case_fixtures"], ids, "Case fixture identities are required")

    for files <- Map.values(r["case_fixtures"]) do
      require!(is_map(files) and map_size(files) > 0, "Missing fixture hashes")

      Enum.each(files, fn {name, digest} ->
        require!(
          is_binary(name) and Path.basename(name) == name and hex?(digest),
          "Invalid fixture identity"
        )
      end)
    end

    require!(is_binary(r["note"]), "note must be text")

    if not is_nil(r["evidence_url"]) do
      url = r["evidence_url"]
      uri = URI.parse(text!(url, "evidence_url"))

      require!(
        uri.scheme in ~w(https http) and is_binary(uri.host) and uri.host != "" and
          is_nil(uri.userinfo),
        "Evidence must be a public HTTP(S) link without embedded credentials"
      )
    end

    r
  end

  defp harness!(%{"name" => "pi"} = harness) do
    fields!(harness, ~w(name version), "Unexpected harness fields")
    text!(harness["version"], "harness version")
  end

  defp harness!(%{"name" => "claude_code"} = harness) do
    fields!(
      harness,
      ~w(name version agent kit_sha256 preamble_sha256),
      "Unexpected harness fields"
    )

    for key <- ~w(version agent), do: text!(harness[key], "harness #{key}")
    for key <- ~w(kit_sha256 preamble_sha256), do: hex!(harness[key], "Invalid #{key}")
  end

  defp harness!(_), do: raise(ArgumentError, "Unknown harness")

  defp hex?(value), do: is_binary(value) and Regex.match?(~r/^[a-f0-9]{64}$/, value)
  defp hex!(value, message), do: require!(hex?(value), message)

  def fields!(value, names, message),
    do: require!(is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(names), message)

  def positive?(value), do: is_integer(value) and value > 0
  def nonnegative?(value), do: is_integer(value) and value >= 0

  def text!(value, name) do
    require!(is_binary(value) and String.trim(value) != "", "#{name} must be nonempty text")
    value
  end

  def date!(value) do
    require!(
      is_binary(value) and match?({:ok, _, _}, DateTime.from_iso8601(value)),
      "Timestamp must include its timezone"
    )
  end

  def require!(condition, message) do
    unless condition, do: raise(ArgumentError, message)
    :ok
  end
end
