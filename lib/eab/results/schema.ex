defmodule Eab.Results.Schema do
  @moduledoc false
  @fields ~w(schema_version series_id benchmark model harness settings setup case_fixtures seeds required_runs runs evidence_url note)
  @run_fields ~w(run_id created_at seed source_release_id code_version deployment cases resources)
  @case_fields ~w(id passed generated_tokens model_calls cutoff)
  @model_fields ~w(name backend quantization quantization_source size_bytes size_source parameter_count quantized_by quantized_by_source source weight_files gguf)
  # A local series made since ADR 0016 has no generation budget, so its max_tokens is null.
  @nullable_int ~w(window_tokens response_tokens max_tokens)
  @integer ~w(safety_tokens)
  @text ~w(budget_policy context_policy reasoning_effort reasoning_effort_source thinking_policy)
  @cutoffs ~w(generation_budget context_budget response_budget)
  @thinking %{
    "server_preset" => ~w(server_reported operator_declared not_reported),
    "provider_request" => ~w(provider_request),
    "harness_agent_file" => ~w(harness_agent_file)
  }

  # Fields each schema version adds to a run and to its cases: timing in 9 (ADR 0019), the
  # machine in 10 (ADR 0020), the patch's own verdict in 11 (ADR 0021), the attempt's peak
  # context in 12 (ADR 0022). In 13 a seeded series takes any seed it does not have yet
  # (ADR 0025). Series published earlier keep their files unchanged and are upgraded when
  # they take another run.
  @versions %{
    8 => {[], []},
    9 => {["timing"], ["timing"]},
    10 => {["timing", "machine"], ["timing"]},
    11 => {["timing", "machine"], ["timing", "patch_passed"]},
    12 => {["timing", "machine"], ["timing", "patch_passed", "peak_context_tokens"]},
    13 => {["timing", "machine"], ["timing", "patch_passed", "peak_context_tokens"]}
  }
  def versions, do: Map.keys(@versions)
  def current_version, do: 13

  def validate!(r) do
    fields!(r, @fields, "Expected a public run series; export the original run.json with add")
    require!(Map.has_key?(@versions, r["schema_version"]), "Unsupported result schema")
    hex!(r["series_id"], "A series ID is required")
    text!(r["benchmark"], "benchmark")
    model!(r["model"], r["setup"])
    harness!(r["harness"])
    settings!(r["settings"])
    require!(is_map(r["setup"]) and map_size(r["setup"]) > 0, "The series setup is required")
    require!(r["required_runs"] === 3, "A run series has three runs")

    if r["schema_version"] >= 13,
      do:
        require!(
          r["seeds"] in [nil, "distinct"],
          "A seeded series takes runs with distinct seeds"
        ),
      else:
        require!(
          is_nil(r["seeds"]) or r["seeds"] == [101, 102, 103],
          "Local series use seeds 101, 102 and 103"
        )

    runs = r["runs"]
    require!(is_list(runs) and length(runs) in 1..3, "A series holds one to three runs")
    ids = Enum.map(hd(runs)["cases"] || [], & &1["id"])
    require!(ids != [] and Enum.uniq(ids) == ids, "Invalid or duplicated case IDs")
    for run <- runs, do: run!(run, r, ids)

    run_ids = Enum.map(runs, & &1["run_id"])
    require!(Enum.uniq(run_ids) == run_ids, "Duplicate run IDs")
    seeds = Enum.map(runs, & &1["seed"])
    require!(is_nil(r["seeds"]) or Enum.uniq(seeds) == seeds, "Each seed counts once")
    require!(Enum.sort_by(runs, & &1["created_at"]) == runs, "Runs are listed oldest first")
    case_fixtures!(r["case_fixtures"], ids)
    allowance!(r["setup"]["allowance"], ids)
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

  @doc false
  def model!(model, setup) do
    fields!(model, @model_fields, "Unexpected model fields")
    for key <- ~w(name backend), do: text!(model[key], key)

    require!(
      model["quantization_source"] in ~w(reported artifact_files owner_supplied not_reported),
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

    # Who made the quantization: named by the served file's GGUF header, or by the owner.
    require!(
      model["quantized_by_source"] in ~w(artifact_files owner_supplied not_reported),
      "Invalid quantized-by source"
    )

    if model["quantized_by_source"] == "not_reported",
      do: require!(is_nil(model["quantized_by"]), "An unreported maker must be null"),
      else:
        require!(
          is_binary(model["quantized_by"]) and String.trim(model["quantized_by"]) != "" and
            String.length(model["quantized_by"]) <= 100,
          "quantized_by must be nonempty text of at most 100 characters"
        )

    weight_files!(model["weight_files"])
    source!(model["source"], model["weight_files"])
    gguf!(model["gguf"])

    # The served files' hashes in the setup are the first run's (ADR 0018).
    if hashes = get_in(setup || %{}, ["model", "sha256"]),
      do:
        require!(
          is_list(model["weight_files"]) and
            Enum.map(model["weight_files"], & &1["sha256"]) == hashes,
          "The setup's weight hashes must be the recorded files'"
        )
  end

  @doc false
  def settings!(settings) do
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
  end

  @doc "Checks one published run of a series or speed record `r` against its case IDs."
  def run!(run, r, ids, opts \\ []) do
    {run_extra, case_extra} = @versions[r["schema_version"]]
    fields!(run, @run_fields ++ run_extra, "Unexpected run fields")

    require!(
      Regex.match?(~r/^[A-Za-z0-9_-]+$/, text!(run["run_id"], "run_id")),
      "Invalid run ID"
    )

    date!(run["created_at"])
    hex!(run["source_release_id"], "A frozen source release ID is required")
    require!(is_nil(run["code_version"]) or hex?(run["code_version"]), "Invalid code version")

    cond do
      opts[:any_seed] -> require!(is_nil(run["seed"]) or is_integer(run["seed"]), "Invalid seed")
      r["seeds"] == "distinct" -> require!(is_integer(run["seed"]), "Each run needs a seed")
      r["seeds"] -> require!(run["seed"] in r["seeds"], "Each run needs one of the series seeds")
      true -> require!(is_nil(run["seed"]), "This series records no seed")
    end

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
      fields!(c, @case_fields ++ case_extra, "Unexpected case fields")
      require!(is_boolean(c["passed"]), "Every case needs a final pass/fail outcome")

      # A case passes only with a passing patch; a token allowance can fail one that has it.
      if "patch_passed" in case_extra,
        do:
          require!(
            is_boolean(c["patch_passed"]) and (c["patch_passed"] or not c["passed"]),
            "patch_passed must be the patch's own verdict"
          )

      require!(
        c["cutoff"] in [nil | @cutoffs],
        "cutoff must be generation_budget, context_budget, response_budget or null"
      )

      # Claude Code cannot enforce the generation budget; going over it is flagged instead.
      require!(
        c["cutoff"] != "generation_budget" or r["harness"]["name"] == "pi",
        "Only Pi enforces the generation budget"
      )

      for key <- ~w(generated_tokens model_calls),
          do:
            require!(
              is_nil(c[key]) or nonnegative?(c[key]),
              "#{key} must be a nonnegative integer or null"
            )

      # An attempt's largest context, or null where the run did not record it.
      if "peak_context_tokens" in case_extra,
        do:
          require!(
            is_nil(c["peak_context_tokens"]) or positive?(c["peak_context_tokens"]),
            "peak_context_tokens must be a positive integer or null"
          )
    end

    # Case times and model speed, when the run recorded them (ADR 0019).
    Eab.Results.Timing.validate!(run, r["harness"]["name"])

    # The machine the model was served on, when the collector identified it (ADR 0020).
    Eab.Results.Machine.validate!(run["machine"])

    require!(
      is_nil(run["machine"]) or run["machine"]["server"] == r["model"]["backend"],
      "The machine's server differs from the model's"
    )

    if not is_nil(run["resources"]),
      do: Eab.Results.Resources.validate!(run["resources"], r["model"], r["settings"], r["setup"])
  end

  # The token allowances a series was made under, when its release has them (ADR 0021).
  @doc false
  def allowance!(nil, _ids), do: :ok

  def allowance!(allowance, ids) do
    fields!(
      allowance,
      ~w(validator multiple minimum_tokens tokens),
      "Unexpected token allowance fields"
    )

    text!(allowance["validator"], "allowance validator")

    require!(
      is_number(allowance["multiple"]) and allowance["multiple"] >= 1 and
        positive?(allowance["minimum_tokens"]),
      "Invalid token allowance rule"
    )

    fields!(allowance["tokens"], ids, "Every case needs its token allowance")

    require!(
      Enum.all?(Map.values(allowance["tokens"]), &positive?/1),
      "A token allowance is a positive integer"
    )
  end

  @doc false
  def case_fixtures!(fixtures, ids) do
    fields!(fixtures, ids, "Case fixture identities are required")

    for files <- Map.values(fixtures) do
      require!(is_map(files) and map_size(files) > 0, "Missing fixture hashes")

      Enum.each(files, fn {name, digest} ->
        require!(
          is_binary(name) and Path.basename(name) == name and hex?(digest),
          "Invalid fixture identity"
        )
      end)
    end
  end

  defp weight_files!(nil), do: :ok

  defp weight_files!(files) do
    require!(is_list(files) and files != [], "weight_files must be a nonempty list or null")

    for file <- files do
      fields!(file, ~w(name size_bytes sha256), "Unexpected weight file fields")
      name = text!(file["name"], "weight file name")
      require!(Path.basename(name) == name, "Only a weight file's name is public")
      require!(positive?(file["size_bytes"]), "Invalid weight file size")
      hex!(file["sha256"], "Invalid weight file sha256")
    end
  end

  defp source!(nil, _files), do: :ok

  defp source!(source, files) do
    fields!(source, Eab.ModelSource.public_fields(), "Unexpected model source fields")
    uri = URI.parse(text!(source["url"], "source url"))

    require!(
      uri.scheme in ~w(https http) and is_binary(uri.host) and uri.host != "" and
        is_nil(uri.userinfo) and is_nil(uri.query),
      "The model source must be an HTTP(S) link without credentials or query"
    )

    for key <- ~w(host path file), do: text!(source[key], "source #{key}")

    for key <- ~w(author repository revision release_label verification_note),
        do: require!(is_nil(source[key]) or text?(source[key]), "Invalid source #{key}")

    require!(
      is_nil(source["release_label"]) or String.length(source["release_label"]) <= 40,
      "The release label is too long"
    )

    require!(source["declared_by"] in ~w(operator publisher), "Invalid source declarer")

    require!(
      is_nil(source["commit"]) or Regex.match?(~r/^[a-f0-9]{40}$/, source["commit"]),
      "Invalid source commit"
    )

    if source["commit_date"], do: date!(source["commit_date"])

    require!(
      source["verification"] in ~w(verified differs not_checked),
      "Invalid source verification"
    )

    if source["verification"] == "verified",
      do:
        require!(
          source["host"] == "huggingface.co" and is_binary(source["commit"]) and
            is_list(files),
          "A verified source names its commit and the hashed files"
        )
  end

  defp gguf!(nil), do: :ok

  defp gguf!(metadata) do
    allowed = Eab.MemoryCollector.Weights.keys() -- ["general.quantized_by"]

    require!(
      is_map(metadata) and map_size(metadata) > 0,
      "gguf must be a nonempty object or null"
    )

    for {key, value} <- metadata do
      require!(key in allowed, "Unexpected GGUF key: #{key}")

      require!(
        is_integer(value) or (text?(value) and byte_size(value) <= 200),
        "Invalid GGUF value for #{key}"
      )
    end
  end

  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  @doc false
  def harness!(%{"name" => "pi"} = harness) do
    fields!(harness, ~w(name version), "Unexpected harness fields")
    text!(harness["version"], "harness version")
  end

  def harness!(%{"name" => "claude_code"} = harness) do
    fields!(
      harness,
      ~w(name version agent kit_sha256 preamble_sha256),
      "Unexpected harness fields"
    )

    for key <- ~w(version agent), do: text!(harness[key], "harness #{key}")
    for key <- ~w(kit_sha256 preamble_sha256), do: hex!(harness[key], "Invalid #{key}")
  end

  def harness!(_), do: raise(ArgumentError, "Unknown harness")

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
