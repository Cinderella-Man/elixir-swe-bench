defmodule Eab.Model do
  @moduledoc "Discovery and native request/accounting adapters for llama.cpp and stock Strata."
  @retry_delays [1_000, 2_000, 4_000, 8_000, 16_000]
  @connect_errors [:econnrefused, :nxdomain, :enetunreach, :ehostunreach]
  @transient_errors @connect_errors ++ [:timeout, :closed, :econnreset]
  @request_phase {__MODULE__, :request_phase}

  @doc false
  def install_transport_observer do
    # One permanent handler avoids leaking per-request handlers when Stop kills
    # a worker. Only request phase is used; telemetry measurements are ignored.
    case :telemetry.attach_many(
           @request_phase,
           [[:finch, :connect, :stop], [:finch, :send, :start]],
           &__MODULE__.observe_transport/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def observe_transport(event, _measurements, metadata, _config) do
    # Finch's synchronous HTTP/1 adapter emits these in the requesting process.
    # Other workers cannot authorize a retry here; unobserved adapters stay conservative.
    if Process.get(@request_phase) do
      phase =
        case event do
          [:finch, :connect, :stop] -> if metadata[:error], do: :connect_failed, else: :connected
          [:finch, :send, :start] -> :sent
        end

      Process.put(@request_phase, phase)
    end

    :ok
  end

  def discover(url, key \\ "") do
    url = normalize_url!(url)
    health = http(url, key, :get, "/health")
    models = http(url, key, :get, "/v1/models")
    props = http(url, key, :get, "/props")

    backend =
      if health["service"] == "strata" or
           String.contains?(String.downcase(to_string(props["build_info"])), "strata"),
         do: "strata",
         else: "llama_cpp"

    alias_name = props["model_alias"]

    unless is_binary(alias_name) and Enum.any?(models["data"] || [], &(&1["id"] == alias_name)),
      do: raise("Endpoint has no unambiguous active model")

    if health["loaded"] == false or health["status"] in ["loading", "error"],
      do: raise("Model is not ready")

    capacity = get_in(props, ["default_generation_settings", "n_ctx"]) || health["context_length"]

    unless is_integer(capacity) and capacity > 16,
      do: raise("Endpoint must report its active context capacity")

    profile =
      Map.take(
        props,
        [
          "model_alias",
          "model_path",
          "model_ftype",
          "build_info",
          "default_generation_settings",
          "chat_template",
          "chat_template_caps",
          "total_slots"
        ] ++ Eab.Thinking.profile_fields()
      )

    row = Enum.find(models["data"], &(&1["id"] == alias_name))

    %{
      "url" => url,
      "backend" => backend,
      "model" => alias_name,
      "context" => capacity,
      "profile" => profile,
      "metadata" => %{"model" => row, "props" => props},
      "identity_note" =>
        "Server-reported identity; artifact checksum and provenance are unverified."
    }
    |> Eab.ModelIdentity.attach()
    |> Eab.Store.scrub(key)
  end

  def settings(endpoint, input \\ %{})
  def settings(%{"backend" => "openai_subscription"}, input), do: Eab.OpenAI.settings(input)

  def settings(%{"backend" => "anthropic"} = endpoint, input),
    do: Eab.Anthropic.settings(endpoint, input)

  def settings(%{"backend" => "claude_code"} = endpoint, input),
    do: Eab.ClaudeCode.settings(endpoint, input)

  def settings(endpoint, input) do
    defaults = Eab.Inventory.definition()["defaults"]

    window =
      integer(
        input,
        "window_tokens",
        min(endpoint["context"], defaults["context_cap_tokens"]),
        32,
        endpoint["context"]
      )

    response =
      integer(
        input,
        "response_tokens",
        min(defaults["response_tokens"], window - 9),
        1,
        window - 9
      )

    %{
      "window_tokens" => window,
      "response_tokens" => response,
      "safety_tokens" => 8,
      "max_tokens" => integer(input, "max_tokens", defaults["max_tokens"], 1, 10_000_000),
      "seed" => integer(input, "seed", defaults["seed"], 0, 2_147_483_647),
      "compaction" => false
    }
    |> Map.merge(Eab.Thinking.settings(endpoint, input))
  end

  def count(endpoint, key, payload) do
    route =
      if endpoint["backend"] == "strata",
        do: "/v1/messages/count_tokens",
        else: "/v1/chat/completions/input_tokens"

    count = http(endpoint["url"], key, :post, route, payload)["input_tokens"]

    unless is_integer(count) and count > 0,
      do: raise("Endpoint did not return an exact prompt count")

    count
  end

  def stream(endpoint, key, payload) do
    route = if endpoint["backend"] == "strata", do: "/v1/messages", else: "/v1/chat/completions"
    http(endpoint["url"], key, :post, route, payload, 1_200_000, :stream)
  end

  # Parse the server's actual usage, independently of Pi's display estimates.
  def stream_usage(endpoint, body, expected_input, allowance) do
    events =
      body
      |> String.split(~r/\r?\n\r?\n/)
      |> Enum.flat_map(fn block ->
        data =
          for "data:" <> line <- String.split(block, ~r/\r?\n/), do: String.trim_leading(line)

        case Enum.join(data, "\n") do
          value when value in ["", "[DONE]"] -> []
          value -> [Jason.decode!(value)]
        end
      end)

    if Enum.any?(events, &(Map.has_key?(&1, "error") or &1["type"] == "error")),
      do: raise("Model stream reported an error")

    {usage, complete} =
      if endpoint["backend"] == "strata" do
        usage =
          Enum.reduce(events, %{}, fn event, acc ->
            Map.merge(acc, get_in(event, ["message", "usage"]) || event["usage"] || %{})
          end)

        {usage, Enum.any?(events, &(&1["type"] == "message_stop"))}
      else
        usage =
          Enum.reduce(events, %{}, fn event, acc -> Map.merge(acc, event["usage"] || %{}) end)

        {usage,
         String.contains?(body, "data: [DONE]") and
           Enum.any?(events, fn event ->
             Enum.any?(event["choices"] || [], &is_binary(&1["finish_reason"]))
           end)}
      end

    # Strata 0.2 reports a prompt as input_tokens 1 plus cache_creation_input_tokens
    # (Anthropic's split); its prompt size is the sum of all three fields.
    {input, output} =
      if endpoint["backend"] == "strata",
        do:
          {usage["input_tokens"]
           |> add_usage(usage["cache_creation_input_tokens"] || 0)
           |> add_usage(usage["cache_read_input_tokens"] || 0), usage["output_tokens"]},
        else: {usage["prompt_tokens"], usage["completion_tokens"]}

    unless complete, do: raise("Model stream ended without a completion marker")
    unless input == expected_input, do: raise("Prompt count differs from generation accounting")

    unless is_integer(output) and output >= 0 and output <= allowance,
      do: raise("Missing or out-of-budget output accounting")

    reasoning = get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0

    unless is_integer(reasoning) and reasoning >= 0 and reasoning <= output,
      do: raise("Invalid reasoning-token accounting")

    %{"input_tokens" => input, "output_tokens" => output}
  end

  def unchanged!(%{"backend" => "openai_subscription"} = endpoint, _key),
    do: Eab.OpenAI.unchanged!(endpoint)

  def unchanged!(%{"backend" => "anthropic"} = endpoint, key),
    do: Eab.Anthropic.unchanged!(endpoint, key)

  def unchanged!(%{"backend" => "claude_code"} = endpoint, _key),
    do: Eab.ClaudeCode.unchanged!(endpoint)

  def unchanged!(endpoint, key) do
    current = discover(endpoint["url"], key)

    unless current["profile"] == endpoint["profile"] and current["backend"] == endpoint["backend"],
      do: raise("Serving model or configuration changed during this run")

    :ok
  end

  def normalize_url!(url) do
    uri = URI.parse(String.trim(url))

    unless uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.userinfo == nil and
             uri.query == nil and uri.fragment == nil,
           do:
             raise(
               ArgumentError,
               "Enter an HTTP endpoint without embedded credentials, query or fragment"
             )

    url = URI.to_string(%{uri | path: String.trim_trailing(uri.path || "", "/")})
    String.replace_suffix(url, "/v1", "")
  end

  def http(url, key, method, route, payload \\ nil, timeout \\ 30_000, format \\ :json) do
    headers =
      [{"anthropic-version", "2023-06-01"}] ++
        if(key == "", do: [], else: [{"authorization", "Bearer " <> key}, {"x-api-key", key}])

    opts = [
      method: method,
      url: url <> route,
      headers: headers,
      retry: false,
      redirect: false,
      receive_timeout: timeout,
      connect_options: [timeout: 10_000],
      decode_body: format != :stream
    ]

    opts = if payload, do: Keyword.put(opts, :json, payload), else: opts
    request = Application.get_env(:eab, :http_request, &Req.request/1)
    activity = Eab.Activity.context()
    stream = make_ref()

    into = fn {:data, data}, {req, response} ->
      if response.status in 200..299 do
        Eab.Activity.inherit(activity, fn -> Eab.Activity.model_chunk(stream, data) end)
      end

      chunks = [data | Map.get(response.private, :eab_chunks, [])]
      {:cont, {req, %{response | private: Map.put(response.private, :eab_chunks, chunks)}}}
    end

    opts = if format == :stream, do: Keyword.put(opts, :into, into), else: opts

    result =
      try do
        request_with_retry(request, opts, route, key, @retry_delays)
      after
        Eab.Activity.model_end(stream)
      end

    result =
      case result do
        {:ok, %{private: %{eab_chunks: chunks}} = response} ->
          {:ok, %{response | body: chunks |> Enum.reverse() |> IO.iodata_to_binary()}}

        other ->
          other
      end

    case result do
      {:ok, %{status: code, body: body}}
      when code in 200..299 and (is_map(body) or (is_binary(body) and format == :stream)) ->
        body

      {:ok, %{status: 401}} when key == "" ->
        raise "Endpoint #{route} requires an API key (HTTP 401). Enter the server's API key under Server credentials and reconnect."

      {:ok, %{status: 401}} ->
        raise "Endpoint #{route} rejected the API key (HTTP 401). Check Server credentials and reconnect."

      {:ok, %{status: code}} when code in 200..299 ->
        expected = if format == :stream, do: "an event stream", else: "a JSON object"

        raise "Endpoint #{route} returned HTTP #{code} with an unexpected response format; expected #{expected}"

      {:ok, %{status: code}} ->
        raise "Endpoint #{route} returned HTTP #{code}"

      {:error, %Req.TransportError{} = error} ->
        detail = Eab.Store.redact(Exception.message(error), key)

        raise "Cannot reach endpoint #{route}: #{detail}. Check the server and network connection."

      {:error, _} ->
        raise "Cannot reach endpoint #{route}; check its address, readiness and credentials"
    end
  end

  @doc false
  # Shared connection-retry policy for hosted transports with their own status handling.
  def request(request, opts, route, key),
    do: request_with_retry(request, opts, route, key, @retry_delays)

  defp request_with_retry(request, opts, route, key, delays) do
    {result, phase} = request_once(request, opts)

    case {result, delays} do
      {{:error, %Req.TransportError{reason: reason} = error}, [delay | remaining]} ->
        if retryable?(reason, opts[:method], route, phase) do
          detail = Eab.Store.redact(Exception.message(error), key)
          detail = if phase == :connect_failed, do: detail <> " before request send", else: detail
          retry = length(@retry_delays) - length(remaining)

          Eab.Activity.note(
            "Endpoint #{route}: #{detail}; retry #{retry}/#{length(@retry_delays)} in #{div(delay, 1_000)}s"
          )

          # Remain in the caller so Stop run drains retries with the owning worker.
          sleep = Application.get_env(:eab, :http_retry_sleep, &Process.sleep/1)
          sleep.(delay)
          request_with_retry(request, opts, route, key, remaining)
        else
          if phase == :sent and route in ["/v1/messages", "/v1/chat/completions"] do
            Eab.Activity.note(
              "Endpoint #{route} failed after request send; generation may have started, so it was not replayed."
            )
          end

          result
        end

      _ ->
        result
    end
  end

  defp request_once(request, opts) do
    previous = Process.put(@request_phase, :unobserved)

    try do
      result = request.(opts)
      {result, Process.get(@request_phase)}
    after
      if previous,
        do: Process.put(@request_phase, previous),
        else: Process.delete(@request_phase)
    end
  end

  defp retryable?(reason, method, route, phase) do
    non_generating =
      method == :get or
        (method == :post and
           route in ["/v1/messages/count_tokens", "/v1/chat/completions/input_tokens"])

    # A generation timeout/reset may follow a submitted request even before the
    # first response chunk. Only definite connection failures are safe to replay.
    if phase == :sent and not non_generating do
      false
    else
      reason in @connect_errors or
        ((non_generating or phase == :connect_failed) and reason in @transient_errors)
    end
  end

  @doc false
  def integer(input, key, default, min, max) do
    value =
      case input[key] do
        nil ->
          default

        "" ->
          default

        v when is_integer(v) ->
          v

        v ->
          case Integer.parse(v) do
            {n, ""} -> n
            _ -> nil
          end
      end

    unless is_integer(value) and value >= min and value <= max,
      do: raise(ArgumentError, "#{key} must be between #{min} and #{max}")

    value
  end

  defp add_usage(a, b) when is_integer(a) and is_integer(b), do: a + b
  defp add_usage(_, _), do: nil
end
