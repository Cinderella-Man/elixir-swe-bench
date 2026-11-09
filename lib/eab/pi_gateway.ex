defmodule Eab.PiGateway do
  @moduledoc "Forwards Pi's native model requests and enforces attempt budgets; never executes tools."
  alias Eab.{Activity, Model, ModelSpeed, Store}

  def request(frame, state) do
    route =
      case state.endpoint["backend"] do
        "openai_subscription" -> "/v1/responses"
        backend when backend in ["strata", "anthropic"] -> "/v1/messages"
        _ -> "/v1/chat/completions"
      end

    unless frame["method"] == "POST" and frame["path"] == route and is_map(frame["body"]),
      do: raise("Pi requested an unsupported endpoint route")

    cond do
      state.error ->
        error_reply(frame, state, state.error)

      state.stop_reason ->
        stopped(frame, state, state.stop_reason)

      state.generated_tokens >= state.settings["max_tokens"] ->
        stopped(frame, state, "token_budget")

      true ->
        exchange(frame, state)
    end
  rescue
    error -> error_reply(frame, state, Store.redact(Exception.message(error), state.key))
  end

  defp exchange(frame, %{endpoint: %{"backend" => "openai_subscription"}} = state) do
    payload = Eab.OpenAI.payload(frame["body"], state.endpoint, state.settings)
    step = state.calls |> Integer.to_string() |> String.pad_leading(4, "0")
    Store.write("#{state.prefix}/request-#{step}.json", payload)
    state = %{state | calls: state.calls + 1}
    persist(state)

    try do
      Activity.note(
        "Model call #{state.calls}: ChatGPT subscription; provider-enforced context. Generated so far: #{state.generated_tokens}/#{state.settings["max_tokens"]} tokens (soft threshold). Waiting for model response…"
      )

      response = Eab.OpenAI.stream(state.endpoint, payload)
      body = response.body
      Store.write_text("#{state.prefix}/response-#{step}.sse", body)
      usage = Eab.OpenAI.usage(response)
      Store.write("#{state.prefix}/usage-#{step}.json", usage)
      state = %{state | generated_tokens: state.generated_tokens + usage["output_tokens"]}
      persist(state)
      stream = make_ref()
      Activity.model_chunk(stream, body)
      Activity.model_end(stream)
      state.emit.("Pi: call #{state.calls}, #{state.generated_tokens} generated tokens")
      {reply(frame, 200, "text/event-stream", body), state}
    rescue
      error in Eab.OpenAI.Error ->
        Eab.OpenAI.pause_for(state.endpoint["account_id"], error)

        details = Eab.OpenAI.error_details(error)
        Store.write("#{state.prefix}/provider-error-#{step}.json", details)
        Store.write("#{state.prefix}/provider-error.json", details)

        error_reply(frame, state, Exception.message(error))

      error ->
        error_reply(frame, state, Exception.message(error))
    end
  end

  defp exchange(frame, %{endpoint: %{"backend" => "anthropic"}} = state) do
    payload = Eab.Anthropic.payload(frame["body"], state.endpoint, state.settings)
    step = state.calls |> Integer.to_string() |> String.pad_leading(4, "0")
    Store.write("#{state.prefix}/request-#{step}.json", payload, state.key)
    state = %{state | calls: state.calls + 1}
    persist(state)

    try do
      Activity.note(
        "Model call #{state.calls}: Claude API; provider-enforced context. Generated so far: #{state.generated_tokens}/#{state.settings["max_tokens"]} tokens (soft threshold). Waiting for model response…"
      )

      body = Eab.Anthropic.stream(state.endpoint, state.key, payload)
      Store.write_text("#{state.prefix}/response-#{step}.sse", body, state.key)
      usage = Eab.Anthropic.usage(body)
      Store.write("#{state.prefix}/usage-#{step}.json", usage, state.key)
      state = %{state | generated_tokens: state.generated_tokens + usage["output_tokens"]}
      persist(state)
      state.emit.("Pi: call #{state.calls}, #{state.generated_tokens} generated tokens")
      {reply(frame, 200, "text/event-stream", body), state}
    rescue
      error in Eab.Anthropic.Error ->
        details = Eab.Anthropic.error_details(error)
        Store.write("#{state.prefix}/provider-error-#{step}.json", details, state.key)
        Store.write("#{state.prefix}/provider-error.json", details, state.key)
        error_reply(frame, state, Store.redact(Exception.message(error), state.key))

      error ->
        error_reply(frame, state, Store.redact(Exception.message(error), state.key))
    end
  end

  defp exchange(frame, state) do
    allowance =
      min(
        state.settings["response_tokens"],
        state.settings["max_tokens"] - state.generated_tokens
      )

    # Preserve Pi's complete messages/tools. Freeze only declared generation settings.
    payload =
      frame["body"]
      |> Map.drop([
        "max_completion_tokens",
        "temperature",
        "top_p",
        "top_k"
      ])
      |> Map.merge(%{
        "model" => state.endpoint["model"],
        "stream" => true,
        "max_tokens" => allowance,
        "seed" => state.settings["seed"]
      })
      |> Eab.Thinking.payload(state.settings)

    payload =
      if state.endpoint["backend"] == "strata",
        do: Map.delete(payload, "tool_choice"),
        else: Map.put(payload, "stream_options", %{"include_usage" => true})

    step = state.calls |> Integer.to_string() |> String.pad_leading(4, "0")
    Store.write("#{state.prefix}/request-#{step}.json", payload, state.key)
    Activity.note("Counting prompt tokens for model call #{state.calls + 1}")
    count = Model.count(state.endpoint, state.key, payload)

    if count + allowance + state.settings["safety_tokens"] > state.settings["window_tokens"] do
      stopped(frame, state, "context_budget")
    else
      state = %{state | calls: state.calls + 1}
      persist(state)

      try do
        Activity.note(
          "Model call #{state.calls}: #{count} prompt tokens " <>
            "(context limit #{state.settings["window_tokens"]}). " <>
            "Generated so far: #{state.generated_tokens}/#{state.settings["max_tokens"]} tokens. " <>
            "Waiting for model response…"
        )

        {body, timing} = Model.stream(state.endpoint, state.key, payload)
        Store.write_text("#{state.prefix}/response-#{step}.sse", body, state.key)
        usage = Model.stream_usage(state.endpoint, body, count, allowance)
        # Speed is recorded only while elapsed time is (ADR 0014).
        speed = if is_map(state.measurement), do: ModelSpeed.call(state.endpoint, body, timing)
        usage = if speed, do: Map.put(usage, "speed", speed), else: usage
        Store.write("#{state.prefix}/usage-#{step}.json", usage, state.key)

        state = %{
          state
          | generated_tokens: state.generated_tokens + usage["output_tokens"],
            speed: ModelSpeed.add(state.speed, speed)
        }

        persist(state)
        state.emit.("Pi: call #{state.calls}, #{state.generated_tokens} generated tokens")
        {reply(frame, 200, "text/event-stream", body), state}
      rescue
        error -> error_reply(frame, state, Store.redact(Exception.message(error), state.key))
      end
    end
  end

  defp stopped(frame, state, reason) do
    Activity.note("Pi stopped: #{reason}")
    state = %{state | stop_reason: reason}
    persist(state)

    {reply(
       frame,
       429,
       "application/json",
       Jason.encode!(%{
         "error" => %{"message" => "Benchmark #{reason} reached", "type" => "budget_exhausted"}
       })
     ), state}
  end

  defp error_reply(frame, state, message) do
    Activity.note("Model error: #{message}")
    state = %{state | error: message}
    persist(state)

    {reply(
       frame,
       502,
       "application/json",
       Jason.encode!(%{"error" => %{"message" => message, "type" => "endpoint_error"}})
     ), state}
  end

  defp reply(frame, status, type, body),
    do: %{"id" => frame["id"], "status" => status, "content_type" => type, "body" => body}

  def persist(state, measurement \\ nil) do
    Store.write(
      "#{state.prefix}/agent-progress.json",
      %{
        "calls" => state.calls,
        "generated_tokens" => state.generated_tokens,
        "stop_reason" => state.stop_reason,
        "error" => state.error,
        "measurement" =>
          measurement ||
            ModelSpeed.attach(Eab.Measurement.finish(state.measurement), state.speed)
      },
      state.key
    )
  end
end
