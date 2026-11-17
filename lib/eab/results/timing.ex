defmodule Eab.Results.Timing do
  @moduledoc """
  Case times and model speed as a published run states them (ADR 0019).

  Each case carries its attempt's elapsed time and summed model speed, or null when none was
  recorded: the run worked on several cases at once, the harness records none, or the record
  predates schema 9. A run carries the sum over its timed cases. Milliseconds are whole.
  """
  import Eab.Results.Schema, only: [fields!: 3, require!: 2, positive?: 1, nonnegative?: 1]

  @speed_fields ~w(source calls prompt_tokens prompt_ms generated_tokens generation_ms draft_tokens draft_accepted)
  @sources ~w(server_reported controller_timed mixed)

  @doc "An attempt's published time and model speed, or nil."
  def of_case(%{"measurement" => %{"attempt_ms" => ms} = measurement}) when is_integer(ms),
    do: %{"time_ms" => ms, "model_speed" => speed(measurement["model_speed"])}

  def of_case(_attempt), do: nil

  defp speed(%{"calls" => calls} = s) when is_integer(calls) and calls > 0 do
    %{
      "source" => s["source"],
      "calls" => calls,
      "prompt_tokens" => s["prompt_tokens"],
      "prompt_ms" => round(s["prompt_ms"]),
      "generated_tokens" => s["generated_tokens"],
      "generation_ms" => round(s["generation_ms"]),
      "draft_tokens" => s["draft_tokens"],
      "draft_accepted" => s["draft_accepted"]
    }
  end

  defp speed(_), do: nil

  @doc "A run's total over the published cases that state a time, or nil when none does."
  def of_run(cases) do
    case cases |> Enum.map(& &1["timing"]) |> Enum.reject(&is_nil/1) do
      [] ->
        nil

      timed ->
        %{
          "measured_cases" => length(timed),
          "time_ms" => timed |> Enum.map(& &1["time_ms"]) |> Enum.sum(),
          "model_speed" =>
            timed
            |> Enum.map(& &1["model_speed"])
            |> Enum.reject(&is_nil/1)
            |> Enum.reduce(nil, &add/2)
        }
    end
  end

  defp add(speed, nil), do: speed

  defp add(speed, sum) do
    Map.new(@speed_fields, fn
      "source" = key -> {key, if(sum[key] == speed[key], do: speed[key], else: "mixed")}
      # Only llama.cpp with a draft model reports draft tokens; the others add nothing.
      key when key in ~w(draft_tokens draft_accepted) -> {key, plus(sum[key], speed[key])}
      key -> {key, sum[key] + speed[key]}
    end)
  end

  defp plus(nil, b), do: b
  defp plus(a, nil), do: a
  defp plus(a, b), do: a + b

  @doc "Checks a run's case timings and that its total sums them."
  def validate!(run, harness) do
    for c <- run["cases"], do: case!(c["timing"])

    require!(
      run["timing"] == of_run(run["cases"]),
      "A run's timing must sum the times of its cases"
    )

    require!(
      is_nil(run["timing"]) or (run["deployment"]["parallel_attempts"] || 1) == 1,
      "Times are recorded only when a run works on one case at a time"
    )

    require!(
      is_nil(run["timing"]) or harness == "pi",
      "Only Pi attempts record their time"
    )
  end

  defp case!(nil), do: :ok

  defp case!(timing) do
    fields!(timing, ~w(time_ms model_speed), "Unexpected case timing fields")
    require!(nonnegative?(timing["time_ms"]), "time_ms must be a nonnegative integer")
    speed!(timing["model_speed"])
  end

  defp speed!(nil), do: :ok

  defp speed!(s) do
    fields!(s, @speed_fields, "Unexpected model speed fields")
    require!(s["source"] in @sources, "Invalid model speed source")
    require!(positive?(s["calls"]), "Model speed needs at least one model call")

    for key <- ~w(prompt_tokens prompt_ms generated_tokens generation_ms),
        do: require!(nonnegative?(s[key]), "#{key} must be a nonnegative integer")

    require!(
      (is_nil(s["draft_tokens"]) and is_nil(s["draft_accepted"])) or
        (nonnegative?(s["draft_tokens"]) and nonnegative?(s["draft_accepted"]) and
           s["draft_accepted"] <= s["draft_tokens"]),
      "Draft tokens and accepted draft tokens go together, with no more accepted than drafted"
    )
  end
end
