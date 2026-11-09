defmodule Eab.ModelSpeed do
  @moduledoc """
  Prompt and generation speed of a Pi attempt's model calls, summed per attempt and run.

  llama.cpp reports its own timings in each stream's final event, excluding the network.
  Strata reports none, so the controller times its stream: from sending the request to the
  first token event, then from the first to the last. Speed is recorded only with the
  attempt's elapsed time (ADR 0014), which assumes a model served on another machine.
  """
  alias Eab.Model

  @doc "One call's speed from its event stream and Strata token times, or nil."
  def call(%{"backend" => "llama_cpp"}, body, _timing) do
    body
    |> Model.events()
    |> Enum.map(& &1["timings"])
    |> Enum.filter(&is_map/1)
    |> List.last()
    |> server_reported()
  end

  def call(%{"backend" => "strata"}, body, %{"first_token_ms" => first, "last_token_ms" => last})
      when first > 0 do
    usage = body |> Model.events() |> Model.strata_usage()
    output = usage["output_tokens"] || 0
    timed = last > first and output > 1

    %{
      "source" => "controller_timed",
      # Strata reports a prompt's uncached part as input plus cache-creation tokens.
      "prompt_tokens" =>
        (usage["input_tokens"] || 0) + (usage["cache_creation_input_tokens"] || 0),
      "prompt_ms" => first,
      # The first token's arrival starts the interval, so it is not counted.
      "generated_tokens" => if(timed, do: output - 1, else: 0),
      "generation_ms" => if(timed, do: last - first, else: 0)
    }
  end

  def call(_endpoint, _body, _timing), do: nil

  defp server_reported(
         %{
           "prompt_n" => prompt,
           "prompt_ms" => prompt_ms,
           "predicted_n" => generated,
           "predicted_ms" => generation_ms
         } = t
       )
       when is_number(prompt) and is_number(prompt_ms) and is_number(generated) and
              is_number(generation_ms) do
    %{
      "source" => "server_reported",
      "prompt_tokens" => prompt,
      "prompt_ms" => prompt_ms,
      "generated_tokens" => generated,
      "generation_ms" => generation_ms
    }
    |> Map.merge(
      if is_integer(t["draft_n"]) and is_integer(t["draft_n_accepted"]),
        do: %{"draft_tokens" => t["draft_n"], "draft_accepted" => t["draft_n_accepted"]},
        else: %{}
    )
  end

  defp server_reported(_), do: nil

  @doc "Adds a call's speed, or another sum, to a sum."
  def add(sum, nil), do: sum
  def add(nil, speed), do: Map.put_new(speed, "calls", 1)

  def add(sum, speed) do
    Map.merge(sum, Map.put_new(speed, "calls", 1), fn
      "source", same, same -> same
      "source", _, _ -> "mixed"
      _, a, b -> a + b
    end)
  end

  @doc "Records an attempt's summed speed with its elapsed time."
  def attach(%{"attempt_ms" => _} = measurement, %{} = speed),
    do: Map.put(measurement, "model_speed", speed)

  def attach(measurement, _speed), do: measurement

  @doc "The summed speed of a run's measured attempts, or nil."
  def of_run(run) do
    (run["attempts"] || %{})
    |> Map.values()
    |> Enum.map(&get_in(&1, ["measurement", "model_speed"]))
    |> Enum.reduce(nil, &add(&2, &1))
  end

  def label(%{"calls" => calls} = speed) do
    [
      rate(speed, "generated_tokens", "generation_ms", "generation"),
      rate(speed, "prompt_tokens", "prompt_ms", "prompt"),
      if((speed["draft_tokens"] || 0) > 0,
        do:
          "#{round(speed["draft_accepted"] * 100 / speed["draft_tokens"])}% of draft tokens accepted"
      ),
      "#{source(speed["source"])} over #{calls} model #{if calls == 1, do: "call", else: "calls"}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  def label(_), do: "Not measured"

  defp rate(speed, tokens, ms, name) do
    if is_number(speed[ms]) and speed[ms] > 0 and is_number(speed[tokens]) and speed[tokens] > 0,
      do: "#{name} #{Float.round(speed[tokens] * 1000 / speed[ms], 1)} tok/s"
  end

  defp source("server_reported"), do: "reported by llama.cpp"
  defp source("controller_timed"), do: "timed by the controller, network included"
  defp source(_), do: "from mixed sources"
end
