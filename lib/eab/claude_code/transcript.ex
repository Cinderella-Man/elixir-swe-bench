defmodule Eab.ClaudeCode.Transcript do
  @moduledoc """
  Reads a Claude Code subagent transcript. Its format is internal to Claude Code, so
  unknown shapes fail closed: the parser is updated, never the check skipped. Usage is
  best effort. Timing fields are removed before the transcript is stored.
  """
  # Records that carry model input or output. Anything else before the prompt is ignored
  # only if it is bookkeeping; an attachment or message before it fails the prompt check.
  @context ~w(user assistant attachment)
  @timing ~w(timestamp durationMs totalDurationMs duration_ms ttftMs elapsedMs startedAt completedAt)

  def parse(text) when is_binary(text) do
    unless String.valid?(text), do: raise("Solver transcript is not UTF-8")

    text
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.map(fn {line, number} ->
      case Jason.decode(line) do
        {:ok, entry} when is_map(entry) -> entry
        _ -> raise "Solver transcript line #{number} is not a JSON object"
      end
    end)
    |> case do
      [] -> raise "Solver transcript is empty"
      entries -> entries
    end
  end

  @doc "Validates the transcript against the frozen prompt and model and summarizes it."
  def check!(entries, prompt, model) do
    context = Enum.filter(entries, &(&1["type"] in @context))

    case context do
      [%{"type" => "user"} = first | _] ->
        unless content_text(first) == prompt,
          do: raise("Solver prompt differs from the frozen harness prompt")

      _ ->
        raise "Solver transcript does not begin with the frozen harness prompt"
    end

    assistants = Enum.filter(entries, &(&1["type"] == "assistant"))

    models =
      for entry <- assistants, m = get_in(entry, ["message", "model"]), m != "<synthetic>", do: m

    if models == [], do: raise("The solver's resolved model cannot be read from its transcript")
    # A dated snapshot of the pinned model is the same model; anything else is a mismatch.
    pinned = ~r/\A#{Regex.escape(model)}(-\d{8})?\z/

    unless Enum.all?(models, &Regex.match?(pinned, &1)),
      do: raise("Solver used #{Enum.join(Enum.uniq(models), ", ")} instead of #{model}")

    versions = entries |> Enum.map(& &1["version"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    version =
      case versions do
        [version] when is_binary(version) -> version
        [] -> raise "Claude Code version cannot be read from the solver transcript"
        _ -> raise "Solver transcript mixes Claude Code versions #{Enum.join(versions, ", ")}"
      end

    usage = usage(assistants)

    Map.merge(usage, %{
      "claude_code_version" => version,
      "agent_id" => Enum.find_value(entries, & &1["agentId"]),
      "model" => model,
      "resolved_models" => Enum.uniq(models),
      "compactions" =>
        Enum.count(entries, &(&1["type"] == "system" and &1["subtype"] == "compact_boundary")),
      "attachments" =>
        entries
        |> Enum.filter(&(&1["type"] == "attachment"))
        |> Enum.map(&(get_in(&1, ["attachment", "type"]) || "unknown"))
        |> Enum.frequencies(),
      "outcome" => outcome(context)
    })
  end

  defp content_text(%{"message" => %{"content" => content}}) when is_binary(content), do: content

  defp content_text(%{"message" => %{"content" => [%{"type" => "text", "text" => text}]}}),
    do: text

  defp content_text(_), do: nil

  # Streaming writes one record per content block with the same message id; the last
  # record's usage is the most complete. Synthetic error messages made no API call.
  defp usage(assistants) do
    calls =
      assistants
      |> Enum.reject(&(get_in(&1, ["message", "model"]) == "<synthetic>"))
      |> Enum.group_by(&(get_in(&1, ["message", "id"]) || &1["uuid"]))
      |> Enum.map(fn {_, records} ->
        Enum.max_by(records, &(get_in(&1, ["message", "usage", "output_tokens"]) || 0))
      end)

    sum = fn field ->
      Enum.reduce(calls, 0, fn record, total ->
        case get_in(record, ["message", "usage", field]) do
          value when is_integer(value) and value >= 0 -> total + value
          _ -> total
        end
      end)
    end

    output = sum.("output_tokens")

    %{
      "calls" => length(calls),
      "generated_tokens" => output,
      "usage" => %{
        "source" => "claude_code_transcript_best_effort",
        "uncached_input_tokens" => sum.("input_tokens"),
        "cache_creation_input_tokens" => sum.("cache_creation_input_tokens"),
        "cache_read_input_tokens" => sum.("cache_read_input_tokens"),
        "output_tokens" => output
      },
      "over_declared_budget" => output > Eab.ClaudeCode.declared_tokens()
    }
  end

  @doc "How the solver ended: completed, a budget/context limit, or an evaluation error."
  def outcome(context) do
    case List.last(context) do
      %{"type" => "assistant"} = last ->
        if api_error?(last), do: classify(last), else: %{"kind" => "completed"}

      _ ->
        %{
          "kind" => "error",
          "message" =>
            "The solver stopped before finishing its response; its transcript ends mid-turn"
        }
    end
  end

  defp api_error?(entry),
    do:
      entry["isApiErrorMessage"] == true or entry["is_api_error_message"] == true or
        (is_binary(entry["error"]) and get_in(entry, ["message", "model"]) == "<synthetic>")

  defp classify(entry) do
    text =
      case get_in(entry, ["message", "content"]) do
        content when is_binary(content) -> content
        content when is_list(content) -> Enum.map_join(content, "\n", &(&1["text"] || ""))
        _ -> ""
      end

    error = entry["error"]

    cond do
      error == "rate_limit" ->
        %{
          "kind" => "usage_limit",
          "message" => "Claude subscription usage limit reached: " <> text
        }

      String.starts_with?(text, "Prompt is too long") or
          String.contains?(text, "reached its context window limit") ->
        %{"kind" => "context_limit", "message" => text}

      error == "max_output_tokens" ->
        %{"kind" => "response_limit", "message" => text}

      true ->
        %{
          "kind" => "error",
          "message" => "Claude Code API error (#{error || "unknown"}): " <> text
        }
    end
  end

  @doc "The transcript as stored: JSON lines without wall-clock or duration fields."
  def without_timing(entries),
    do: Enum.map_join(entries, "", &(Jason.encode!(drop_timing(&1)) <> "\n"))

  defp drop_timing(value) when is_map(value),
    do: value |> Map.drop(@timing) |> Map.new(fn {k, v} -> {k, drop_timing(v)} end)

  defp drop_timing(value) when is_list(value), do: Enum.map(value, &drop_timing/1)
  defp drop_timing(value), do: value
end
