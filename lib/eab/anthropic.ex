defmodule Eab.Anthropic.Error do
  defexception [:message, :status, :type, :request_id, :body]
end

defmodule Eab.Anthropic do
  @moduledoc "Claude API discovery and Messages transport for the existing Pi runner."
  alias Eab.{Activity, Model, Store}
  @url "https://api.anthropic.com"
  @efforts ~w(low medium high xhigh max)
  # 429 and 529 mean the API rejected the request before generating; other statuses are final.
  @busy_delays [2_000, 4_000, 8_000, 16_000, 32_000]
  @unsupported ~w(temperature top_p top_k metadata)

  def efforts, do: @efforts

  def effort_label("xhigh"), do: "Extra high (xhigh)"
  def effort_label("default"), do: "API default"
  def effort_label(effort), do: String.capitalize(effort)

  def endpoint?(url) do
    Model.normalize_url!(url) == @url
  rescue
    _ -> false
  end

  def catalog(key) do
    body = request(key, :get, "/v1/models?limit=100")
    unless is_list(body["data"]), do: raise("Anthropic did not return a model catalog")
    rows = Enum.filter(body["data"], &is_binary(&1["id"]))
    if rows == [], do: raise("No models are available to this API key")
    Enum.map(rows, &row/1)
  end

  defp row(model) do
    %{
      "id" => model["id"],
      "display_name" => model["display_name"] || model["id"],
      "max_input_tokens" => model["max_input_tokens"],
      "max_tokens" => model["max_tokens"],
      "adaptive_thinking" =>
        get_in(model, ["capabilities", "thinking", "types", "adaptive", "supported"]) == true,
      "efforts" =>
        Enum.filter(
          @efforts,
          &(get_in(model, ["capabilities", "effort", &1, "supported"]) == true)
        )
    }
  end

  def endpoint(row) do
    %{
      "url" => @url,
      "backend" => "anthropic",
      "model" => row["id"],
      "context" => row["max_input_tokens"],
      "profile" =>
        Map.merge(
          %{"transport" => "messages", "billing" => "anthropic_api"},
          Map.take(row, ~w(max_tokens adaptive_thinking efforts))
        ),
      "metadata" => %{"model" => row},
      "identity" => %{
        "version" => 1,
        "name" => row["display_name"],
        "quantization" => nil,
        "artifact" => nil,
        "source" => "reported_name",
        "size_bytes" => nil,
        "parameter_count" => nil
      },
      "identity_note" => "Claude API model alias; the serving snapshot is not reported."
    }
  end

  def unchanged!(endpoint, key) do
    assert_endpoint!(endpoint)

    unless request(key, :get, "/v1/models/" <> URI.encode(endpoint["model"]))["id"] ==
             endpoint["model"],
           do: raise("Selected model is no longer available to this API key")

    :ok
  end

  def settings(endpoint, input) do
    profile = endpoint["profile"] || %{}
    cap = profile["max_tokens"] || 64_000
    effort = input["reasoning_effort"] || "high"

    unless effort in ["default" | profile["efforts"] || []],
      do: raise(ArgumentError, "This model does not support #{effort} effort")

    %{
      "max_tokens" => Model.integer(input, "max_tokens", 262_144, 1, 10_000_000),
      # The API needs a per-reply value; new runs ask for the model's maximum (ADR 0015).
      "response_tokens" => Model.integer(input, "response_tokens", cap, 1, cap),
      "window_tokens" => endpoint["context"],
      "budget_policy" => "response_boundary_soft_limit",
      "context_policy" => "provider_enforced",
      "seed" => nil,
      "compaction" => false,
      "reasoning_effort" => effort,
      "reasoning_effort_source" => "provider_request",
      "thinking_policy" => "provider_request"
    }
  end

  def payload(body, endpoint, settings) do
    assert_endpoint!(endpoint)
    unless is_list(body["messages"]), do: raise("Pi must provide complete Messages history")

    # Keep Pi's messages, tools, thinking signatures and cache breakpoints intact.
    # Freeze only the model, response cap, thinking display and selected effort.
    body =
      body
      |> Map.drop(@unsupported)
      |> Map.merge(%{
        "model" => endpoint["model"],
        "stream" => true,
        "max_tokens" => settings["response_tokens"]
      })

    body =
      if endpoint["profile"]["adaptive_thinking"],
        do: Map.put(body, "thinking", %{"type" => "adaptive", "display" => "summarized"}),
        else: Map.delete(body, "thinking")

    config = Map.delete(body["output_config"] || %{}, "effort")

    config =
      if settings["reasoning_effort"] == "default",
        do: config,
        else: Map.put(config, "effort", settings["reasoning_effort"])

    if config == %{},
      do: Map.delete(body, "output_config"),
      else: Map.put(body, "output_config", config)
  end

  def stream(endpoint, key, payload) do
    assert_endpoint!(endpoint)
    request(key, :post, "/v1/messages", payload)
  end

  def usage(body) do
    events =
      body
      |> String.split(~r/\r?\n\r?\n/)
      |> Enum.flat_map(fn block ->
        lines =
          for "data:" <> line <- String.split(block, ~r/\r?\n/), do: String.trim_leading(line)

        case Enum.join(lines, "\n") do
          "" -> []
          value -> [Jason.decode!(value)]
        end
      end)

    if error = Enum.find(events, &(&1["type"] == "error")) do
      raise Eab.Anthropic.Error,
        message: failure(get_in(error, ["error", "type"]), get_in(error, ["error", "message"])),
        type: get_in(error, ["error", "type"]),
        body: error
    end

    unless Enum.any?(events, &(&1["type"] == "message_stop")),
      do: raise("Claude stream ended without message_stop; this attempt is an error")

    usage =
      Enum.reduce(events, %{}, fn event, acc ->
        Map.merge(acc, get_in(event, ["message", "usage"]) || event["usage"] || %{})
      end)

    parts =
      Enum.map(
        ~w(input_tokens cache_creation_input_tokens cache_read_input_tokens),
        &(usage[&1] || 0)
      )

    output = usage["output_tokens"]

    unless Enum.all?([output | parts], &(is_integer(&1) and &1 >= 0)),
      do: raise("Claude returned missing or invalid usage accounting")

    [uncached, written, read] = parts

    %{
      "input_tokens" => uncached + written + read,
      "output_tokens" => output,
      "uncached_input_tokens" => uncached,
      "cache_creation_input_tokens" => written,
      "cache_read_input_tokens" => read,
      "stop_reason" =>
        events
        |> Enum.map(&get_in(&1, ["delta", "stop_reason"]))
        |> Enum.reject(&is_nil/1)
        |> List.last()
    }
  end

  def error_details(error), do: Map.from_struct(error) |> Map.drop([:__exception__])

  defp assert_endpoint!(endpoint) do
    unless endpoint["url"] == @url and endpoint["backend"] == "anthropic",
      do: raise("Claude API keys can only be sent to https://api.anthropic.com")
  end

  defp request(key, method, route, payload \\ nil) do
    if key == "", do: raise("Enter a Claude API key")
    activity = Activity.context()
    stream = make_ref()

    into = fn {:data, data}, {req, response} ->
      if response.status in 200..299 do
        Activity.inherit(activity, fn -> Activity.model_chunk(stream, data) end)
      end

      chunks = [data | Map.get(response.private, :eab_chunks, [])]
      {:cont, {req, %{response | private: Map.put(response.private, :eab_chunks, chunks)}}}
    end

    opts =
      [
        url: @url <> route,
        method: method,
        headers: [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}],
        retry: false,
        redirect: false,
        receive_timeout: if(payload, do: 1_200_000, else: 30_000),
        connect_options: [timeout: 10_000],
        decode_body: is_nil(payload)
      ] ++ if(payload, do: [json: payload, into: into], else: [])

    try do
      busy(opts, route, key, @busy_delays)
    after
      if payload, do: Activity.model_end(stream)
    end
  end

  defp busy(opts, route, key, delays) do
    transport = Application.get_env(:eab, :http_request, &Req.request/1)

    case Model.request(transport, opts, route, key) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        case response do
          %{private: %{eab_chunks: chunks}} ->
            chunks |> Enum.reverse() |> IO.iodata_to_binary() |> Store.scrub(key)

          _ ->
            Store.scrub(response.body, key)
        end

      {:ok, %{status: status} = response} when status in [429, 529] and delays != [] ->
        [delay | remaining] = delays
        delay = retry_after(response) || delay
        retry = length(@busy_delays) - length(remaining)

        Activity.note(
          "Claude API #{route}: HTTP #{status}; not started, retry #{retry}/#{length(@busy_delays)} in #{div(delay, 1_000)}s"
        )

        Application.get_env(:eab, :http_retry_sleep, &Process.sleep/1).(delay)
        busy(opts, route, key, remaining)

      {:ok, %{status: status} = response} ->
        raise error(response, status, key)

      {:error, %Req.TransportError{} = error} ->
        raise "Cannot reach the Claude API #{route}: #{Store.redact(Exception.message(error), key)}; the request was not replayed"

      _ ->
        raise "Claude API connection failed; the request was not replayed"
    end
  end

  defp retry_after(response) do
    with [value | _] <- response |> Map.get(:headers, %{}) |> Map.get("retry-after", []),
         {seconds, ""} <- Integer.parse(value),
         true <- seconds in 1..120 do
      seconds * 1_000
    else
      _ -> nil
    end
  end

  defp error(response, status, key) do
    body =
      case response do
        %{private: %{eab_chunks: chunks}} -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
        _ -> response.body
      end

    decoded =
      with true <- is_binary(body), {:ok, data} <- Jason.decode(body) do
        Store.scrub(data, key)
      else
        _ -> Store.scrub(body, key)
      end

    type = if is_map(decoded), do: get_in(decoded, ["error", "type"])
    detail = if is_map(decoded), do: get_in(decoded, ["error", "message"])

    request_id =
      response
      |> Map.get(:headers, %{})
      |> Map.get("request-id", [])
      |> List.wrap()
      |> List.first()

    %Eab.Anthropic.Error{
      message:
        if(status == 401,
          do: "The Claude API rejected the API key (HTTP 401). Check the key and reconnect.",
          else: failure(type, detail) <> " (HTTP #{status})"
        ),
      status: status,
      type: type,
      request_id: request_id,
      body: decoded
    }
  end

  defp failure(type, detail) when is_binary(type),
    do: "Claude API rejected the request (#{type}): #{detail || "no detail"}"

  defp failure(_, _), do: "Claude API returned a failed or incomplete response"
end
