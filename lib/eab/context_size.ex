defmodule Eab.ContextSize do
  @moduledoc """
  How much context an attempt needed, and a run's score at smaller context sizes (ADR 0022).

  An attempt's **peak context** is the largest conversation any of its model calls held: the
  prompt that call was sent plus the reply it generated. History is never compacted, so it is
  what the attempt needed to finish. A case counts at a context size only if the agent
  finished on its own with its whole attempt inside that size and its patch passes. One run
  at the largest window therefore gives a score at every smaller size, with nothing run or
  graded again.
  """
  alias Eab.{Series, Store}

  # From what a small local setup holds to the largest window local runs use.
  @sizes [65_536, 98_304, 131_072, 196_608, 262_144]

  def sizes, do: @sizes

  @doc """
  One model call's context: its prompt and its reply. Anthropic's raw accounting, as a Claude
  Code transcript holds it, splits the prompt into uncached, cache-written and cache-read
  tokens. The gateway's usage records already hold the whole prompt as `input_tokens`, and
  mark that with `uncached_input_tokens` where they keep the split beside it.
  """
  def of_call(usage) do
    {prompt, reply} = split(usage)
    prompt + reply
  end

  # A call's prompt and reply tokens; zeros when its usage record is not one.
  defp split(usage) when is_map(usage) do
    keys =
      if Map.has_key?(usage, "uncached_input_tokens"),
        do: ~w(input_tokens),
        else: ~w(input_tokens cache_creation_input_tokens cache_read_input_tokens)

    prompt = Enum.map(keys, &(usage[&1] || 0))
    reply = usage["output_tokens"] || 0

    if Enum.all?([reply | prompt], &(is_integer(&1) and &1 >= 0)),
      do: {Enum.sum(prompt), reply},
      else: {0, 0}
  end

  defp split(_), do: {0, 0}

  @doc "The larger of the peak so far and this call's context."
  def peak(previous, usage), do: max(previous || 0, of_call(usage))

  @doc """
  An attempt's peak context: as it recorded it, or read from the per-call usage records or
  the Claude Code transcript a run made before this was recorded still holds. Nil when
  neither exists.
  """
  def of_attempt(run_id, case_id, attempt) do
    case attempt["peak_context_tokens"] do
      tokens when is_integer(tokens) and tokens > 0 ->
        tokens

      _ ->
        if Store.valid_id?(run_id) and Store.valid_id?(case_id),
          do: from_files(run_id, case_id)
    end
  end

  defp from_files(run_id, case_id) do
    case run_id |> calls(case_id) |> Enum.map(fn {prompt, reply} -> prompt + reply end) do
      [] -> nil
      contexts -> if Enum.max(contexts) > 0, do: Enum.max(contexts)
    end
  end

  @doc """
  Every model call of an attempt as `{prompt_tokens, reply_tokens}`, in call order, read from
  the Claude Code transcript or the per-call usage records its folder holds. Empty when it
  holds neither.
  """
  def calls(run_id, case_id) do
    directory = Store.path("runs/#{run_id}/#{case_id}")
    transcript = Path.join(directory, "claude-transcript.jsonl")

    if File.regular?(transcript) do
      transcript_calls(transcript)
    else
      for path <- Enum.sort(Path.wildcard(Path.join(directory, "usage-*.json"))),
          {:ok, usage} <- [Jason.decode(File.read!(path))],
          do: split(usage)
    end
  end

  @doc false
  def from_transcript(path),
    do: path |> transcript_calls() |> Enum.map(fn {prompt, reply} -> prompt + reply end)

  @doc false
  # Streaming writes one record per content block with the same message id; the one holding
  # the most is the complete call. Synthetic error messages made no model call.
  def transcript_calls(path) do
    {order, calls} =
      path
      |> File.stream!()
      |> Enum.reduce({[], %{}}, fn line, {order, calls} = seen ->
        case Jason.decode(line) do
          {:ok, %{"type" => "assistant", "message" => %{"usage" => usage} = message} = record}
          when is_map(usage) ->
            if message["model"] == "<synthetic>" do
              seen
            else
              id = message["id"] || record["uuid"]
              call = split(usage)
              order = if Map.has_key?(calls, id), do: order, else: [id | order]
              {order, Map.update(calls, id, call, &larger(&1, call))}
            end

          _ ->
            seen
        end
      end)

    order |> Enum.reverse() |> Enum.map(&calls[&1])
  end

  defp larger({p1, r1} = one, {p2, r2} = other), do: if(p2 + r2 > p1 + r1, do: other, else: one)

  @doc "Whether a published case counts at a context size: finished on its own, inside it, and right."
  def fits?(published_case, size) do
    tokens = published_case["peak_context_tokens"]

    published_case["passed"] == true and is_nil(published_case["cutoff"]) and
      is_integer(tokens) and tokens <= size
  end

  @doc "Whether every attempt of a published series recorded its peak context."
  def recorded?(record) do
    Enum.all?(record["runs"], fn run ->
      Enum.all?(run["cases"], &is_integer(&1["peak_context_tokens"]))
    end)
  end

  @doc """
  A published series' score at each context size, keyed by the size as text: the mean of its
  runs, the rerun interval and each case's pass count, computed as the series' own score is.
  Nil for a series whose attempts did not all record their peak context.
  """
  def scores(record) do
    if recorded?(record) do
      Map.new(@sizes, fn size ->
        runs =
          Enum.map(record["runs"], fn run ->
            %{
              "cases" => Enum.map(run["cases"], &%{"id" => &1["id"], "passed" => fits?(&1, size)})
            }
          end)

        {Integer.to_string(size),
         Map.take(Series.summary(runs), ~w(score_percent interval_percent case_passes))}
      end)
    end
  end
end
