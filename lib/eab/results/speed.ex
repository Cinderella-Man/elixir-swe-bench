defmodule Eab.Results.Speed do
  @moduledoc """
  Published speed runs (ADR 0020): one run of a model on the benchmark's speed cases, one case
  at a time, kept for its times, model speed and machine. It is never scored and joins no run
  series; `series_id` names the series its setup belongs to, published or not. One file per
  run lives in `speed/` beside `results/`, or in `releases/<name>/speed/` for an earlier release.
  """
  alias Eab.Results.Schema
  import Schema, only: [fields!: 3, require!: 2, text!: 2]

  @fields ~w(schema_version kind series_id benchmark model harness settings setup case_fixtures run note)

  def validate!(s) do
    fields!(s, @fields, "Expected a public speed run; export the original run.json with add")

    # Speed runs began with schema 10; 11 adds each case's patch verdict (ADR 0021) and 12
    # its peak context (ADR 0022). 13 changes only how a series takes seeds (ADR 0025).
    require!(
      s["schema_version"] in [10, 11, 12, 13] and s["kind"] == "speed_run",
      "Unsupported speed run schema"
    )

    require!(hex?(s["series_id"]), "A series ID is required")
    text!(s["benchmark"], "benchmark")
    Schema.model!(s["model"], s["setup"])
    Schema.harness!(s["harness"])
    require!(s["harness"]["name"] == "pi", "Only Pi attempts record their time")
    Schema.settings!(s["settings"])
    require!(is_map(s["setup"]) and map_size(s["setup"]) > 0, "The setup is required")

    run = s["run"]
    require!(is_map(run), "A speed record holds one run")
    ids = Enum.map(run["cases"] || [], & &1["id"])
    require!(ids != [] and Enum.uniq(ids) == ids, "Invalid or duplicated case IDs")
    Schema.run!(run, Map.put(s, "seeds", nil), ids, any_seed: true)

    require!(
      is_map(run["machine"]),
      "A speed run names the machine its model was served on; run it with the memory collector"
    )

    require!(
      Enum.all?(run["cases"], &is_map(&1["timing"])),
      "Every case of a speed run states its time"
    )

    Schema.case_fixtures!(s["case_fixtures"], ids)
    require!(is_binary(s["note"]), "note must be text")
    s
  end

  @doc "The speed runs in a directory, validated; a missing directory holds none."
  def load!(directory) do
    Path.wildcard(Path.join(directory, "*.json"))
    |> Enum.sort()
    |> Enum.map(fn path ->
      try do
        record = path |> File.read!() |> Jason.decode!() |> validate!()

        require!(
          Path.basename(path, ".json") == record["run"]["run_id"],
          "File name must be the run ID"
        )

        record
      rescue
        error -> raise ArgumentError, "#{Path.basename(path)}: #{Exception.message(error)}"
      end
    end)
  end

  defp hex?(value), do: is_binary(value) and Regex.match?(~r/^[a-f0-9]{64}$/, value)
end
