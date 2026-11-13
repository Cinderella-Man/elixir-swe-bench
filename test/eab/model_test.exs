defmodule Eab.ModelTest do
  use ExUnit.Case, async: false
  alias Eab.Model

  setup do
    parent = self()
    Application.put_env(:eab, :http_retry_sleep, fn ms -> send(parent, {:retry_wait, ms}) end)

    on_exit(fn ->
      Application.delete_env(:eab, :http_request)
      Application.delete_env(:eab, :http_retry_sleep)
    end)

    :ok
  end

  defp endpoint(backend \\ "llama_cpp"),
    do: %{"backend" => backend, "model" => "test", "url" => "http://fixture", "context" => 32768}

  defp stalled_server do
    parent = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, data} = :gen_tcp.recv(socket, 0, 3_000)
        send(parent, {:peer_received, data})

        receive do
          :stop -> :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :kill)
    end)

    port
  end

  test "automatic budgets adapt to capacity and invalid overrides are rejected" do
    assert Model.settings(endpoint())["window_tokens"] == 32768
    assert Model.settings(%{"context" => 500_000})["window_tokens"] == 262_144

    assert_raise ArgumentError, fn ->
      Model.settings(endpoint(), %{"window_tokens" => "50000"})
    end

    assert_raise ArgumentError, fn -> Model.settings(endpoint(), %{"max_tokens" => "1oops"}) end
    refute Map.has_key?(Model.settings(endpoint(), %{"max_calls" => "32"}), "max_calls")
  end

  test "a local run has no generation budget unless it is an older run's own" do
    # The context window is the only limit (ADR 0016).
    assert is_nil(Model.settings(endpoint())["max_tokens"])
    assert is_nil(Model.settings(endpoint(), %{"max_tokens" => ""})["max_tokens"])
    # A run made with a budget keeps it when it is resumed.
    assert Model.settings(endpoint(), %{"max_tokens" => 65_536})["max_tokens"] == 65_536
    assert Model.local?(endpoint())
    assert Model.local?(%{"backend" => "strata"})
    refute Model.local?(%{"backend" => "anthropic"})
    refute Model.local?(%{"backend" => "openai_subscription"})
    refute Model.local?(%{"backend" => "claude_code"})
  end

  test "stream accounting includes cached input and rejects missing or excessive usage" do
    strata =
      "data: " <>
        Jason.encode!(%{
          "type" => "message_delta",
          "usage" => %{
            "input_tokens" => 10,
            "cache_read_input_tokens" => 90,
            "output_tokens" => 12
          }
        }) <> "\n\ndata: {\"type\":\"message_stop\"}\n\n"

    assert Model.stream_usage(endpoint("strata"), strata, 100, 20)["output_tokens"] == 12
    assert_raise RuntimeError, fn -> Model.stream_usage(endpoint("strata"), strata, 10, 20) end
    assert_raise RuntimeError, fn -> Model.stream_usage(endpoint("strata"), strata, 100, 11) end

    # Strata 0.2 streams the whole prompt first, then re-reports it as one input
    # token plus cache creation and reuse.
    strata_0_2 =
      "data: " <>
        Jason.encode!(%{
          "type" => "message_start",
          "message" => %{"usage" => %{"input_tokens" => 100, "output_tokens" => 0}}
        }) <>
        "\n\ndata: " <>
        Jason.encode!(%{
          "type" => "message_delta",
          "usage" => %{
            "input_tokens" => 1,
            "cache_creation_input_tokens" => 65,
            "cache_read_input_tokens" => 34,
            "output_tokens" => 12
          }
        }) <>
        "\n\ndata: {\"type\":\"message_stop\"}\n\n"

    assert Model.stream_usage(endpoint("strata"), strata_0_2, 100, 20)["input_tokens"] == 100

    assert_raise RuntimeError, fn ->
      Model.stream_usage(endpoint("strata"), strata_0_2, 35, 20)
    end

    llama =
      "data: " <>
        Jason.encode!(%{
          "choices" => [%{"finish_reason" => "stop"}],
          "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 5}
        }) <> "\n\ndata: [DONE]\n\n"

    assert Model.stream_usage(endpoint(), llama, 20, 8)["output_tokens"] == 5
    assert_raise RuntimeError, fn -> Model.stream_usage(endpoint(), "data: [DONE]\n\n", 20, 8) end

    assert_raise RuntimeError, fn ->
      Model.stream_usage(endpoint(), String.replace(llama, "[DONE]", ""), 20, 8)
    end
  end

  test "discovery is non-generating and redacts credentials from returned metadata" do
    parent = self()

    Application.put_env(:eab, :http_request, fn opts ->
      send(parent, {:request, opts})

      body =
        case URI.parse(opts[:url]).path do
          "/health" ->
            %{"status" => "ok", "service" => "strata", "loaded" => true}

          "/v1/models" ->
            %{"data" => [%{"id" => "test", "note" => "secret-token"}]}

          "/props" ->
            %{"model_alias" => "test", "default_generation_settings" => %{"n_ctx" => 32768}}
        end

      {:ok, %{status: 200, body: body}}
    end)

    result = Model.discover("http://fixture/v1", "secret-token")
    assert result["backend"] == "strata"
    refute Jason.encode!(result) =~ "secret-token"

    for _ <- 1..3 do
      assert_receive {:request, opts}
      assert opts[:method] == :get
      assert opts[:redirect] == false
    end
  end

  test "URL parsing forbids embedded secrets and Strata counting is non-generating" do
    assert_raise ArgumentError, fn -> Model.normalize_url!("http://user:secret@host") end
    parent = self()

    Application.put_env(:eab, :http_request, fn opts ->
      send(parent, {:request, opts})
      {:ok, %{status: 200, body: %{"input_tokens" => 42}}}
    end)

    assert Model.count(endpoint("strata"), "", %{"messages" => []}) == 42
    assert_receive {:request, opts}
    assert opts[:url] == "http://fixture/v1/messages/count_tokens"
  end

  test "authentication failures explain the credentials field without blaming JSON or revealing keys" do
    Application.put_env(:eab, :http_request, fn _ ->
      {:ok,
       %{
         status: 401,
         body: %{
           "error" => %{"type" => "authentication_error", "message" => "missing or wrong API key"}
         }
       }}
    end)

    assert_raise RuntimeError,
                 "Endpoint /v1/models requires an API key (HTTP 401). Enter the server's API key under Server credentials and reconnect.",
                 fn ->
                   Model.http("http://fixture", "", :get, "/v1/models")
                 end

    assert_raise RuntimeError,
                 "Endpoint /v1/models rejected the API key (HTTP 401). Check Server credentials and reconnect.",
                 fn ->
                   Model.http("http://fixture", "private-key", :get, "/v1/models")
                 end
  end

  test "HTTP errors and successful non-JSON replies are reported separately" do
    Application.put_env(:eab, :http_request, fn _ ->
      {:ok, %{status: 503, body: "Unavailable"}}
    end)

    assert_raise RuntimeError, "Endpoint /props returned HTTP 503", fn ->
      Model.http("http://fixture", "", :get, "/props")
    end

    Application.put_env(:eab, :http_request, fn _ ->
      {:ok, %{status: 200, body: "<html>Login</html>"}}
    end)

    assert_raise RuntimeError,
                 "Endpoint /props returned HTTP 200 with an unexpected response format; expected a JSON object",
                 fn ->
                   Model.http("http://fixture", "", :get, "/props")
                 end
  end

  test "connection failures preserve the transport reason instead of suggesting credentials" do
    for {reason, detail} <- [timeout: "timeout", econnrefused: "connection refused"] do
      Application.put_env(:eab, :http_request, fn _ ->
        {:error, %Req.TransportError{reason: reason}}
      end)

      assert_raise RuntimeError,
                   "Cannot reach endpoint /v1/messages/count_tokens: #{detail}. Check the server and network connection.",
                   fn -> Model.count(endpoint("strata"), "private-key", %{"messages" => []}) end
    end
  end

  test "token counting recovers from transient failures with the same payload before generation" do
    parent = self()
    payload = %{"messages" => [%{"role" => "user", "content" => "repair this"}]}

    for backend <- ["strata", "llama_cpp"] do
      attempts = :counters.new(1, [])

      Application.put_env(:eab, :http_request, fn opts ->
        send(parent, {:request, opts})
        :counters.add(attempts, 1, 1)

        case :counters.get(attempts, 1) do
          1 -> {:error, %Req.TransportError{reason: :timeout}}
          2 -> {:error, %Req.TransportError{reason: :econnreset}}
          _ -> {:ok, %{status: 200, body: %{"input_tokens" => 42}}}
        end
      end)

      assert Model.count(endpoint(backend), "private-key", payload) == 42
      assert :counters.get(attempts, 1) == 3
      assert_receive {:retry_wait, 1000}
      assert_receive {:retry_wait, 2000}
      refute_receive {:retry_wait, _}

      for _ <- 1..3 do
        assert_receive {:request, opts}
        assert opts[:json] == payload
        assert opts[:retry] == false
        assert String.ends_with?(opts[:url], "tokens")
      end
    end
  end

  test "metadata connection retries are bounded and preserve the final failure" do
    parent = self()

    Application.put_env(:eab, :http_request, fn _ ->
      send(parent, :request)
      {:error, %Req.TransportError{reason: :timeout}}
    end)

    assert_raise RuntimeError, ~r/\/health: timeout/, fn ->
      Model.http("http://fixture", "", :get, "/health")
    end

    for delay <- [1000, 2000, 4000, 8000, 16000] do
      assert_receive :request
      assert_receive {:retry_wait, ^delay}
    end

    assert_receive :request
    refute_receive :request
    refute_receive {:retry_wait, _}
  end

  test "generation retries connection refusal but does not replay ambiguous failures" do
    parent = self()
    attempts = :counters.new(1, [])

    Application.put_env(:eab, :http_request, fn _ ->
      :counters.add(attempts, 1, 1)

      if :counters.get(attempts, 1) == 1,
        do: {:error, %Req.TransportError{reason: :econnrefused}},
        else: {:ok, %{status: 200, body: "data: [DONE]\n\n"}}
    end)

    assert Model.stream(endpoint("strata"), "", %{}) == {"data: [DONE]\n\n", nil}
    assert :counters.get(attempts, 1) == 2
    assert_receive {:retry_wait, 1000}

    for reason <- [:timeout, :closed, :econnreset] do
      Application.put_env(:eab, :http_request, fn _ ->
        send(parent, :request)
        {:error, %Req.TransportError{reason: reason}}
      end)

      assert_raise RuntimeError, fn -> Model.stream(endpoint("strata"), "", %{}) end
      assert_receive :request
      refute_receive :request
      refute_receive {:retry_wait, _}
    end
  end

  test "HTTP errors, invalid responses and permanent transport failures are not retried" do
    parent = self()

    for result <- [
          {:ok, %{status: 401, body: %{}}},
          {:ok, %{status: 400, body: %{}}},
          {:ok, %{status: 503, body: %{}}},
          {:ok, %{status: 200, body: "not JSON"}},
          {:error, %Req.TransportError{reason: :eacces}}
        ] do
      Application.put_env(:eab, :http_request, fn _ ->
        send(parent, :request)
        result
      end)

      assert_raise RuntimeError, fn -> Model.count(endpoint("strata"), "", %{}) end
      assert_receive :request
      refute_receive :request
      refute_receive {:retry_wait, _}
    end
  end

  test "a real connection-handshake timeout retries generation before any request is sent" do
    port = stalled_server()
    parent = self()
    attempts = :counters.new(1, [])

    Application.put_env(:eab, :http_request, fn opts ->
      :counters.add(attempts, 1, 1)

      if :counters.get(attempts, 1) == 1 do
        # The peer accepts TCP but never completes TLS. This exercises Finch's
        # actual pre-request timeout path without sending a generation request.
        result = Req.request(Keyword.put(opts, :connect_options, timeout: 100))
        send(parent, {:transport_result, result})
        result
      else
        {:ok, %{status: 200, body: "data: [DONE]\n\n"}}
      end
    end)

    model = Map.put(endpoint("strata"), "url", "https://127.0.0.1:#{port}")
    assert Model.stream(model, "", %{}) == {"data: [DONE]\n\n", nil}
    assert_receive {:transport_result, {:error, %Req.TransportError{reason: :timeout}}}
    assert_receive {:retry_wait, 1000}
    assert :counters.get(attempts, 1) == 2
    refute_receive {:retry_wait, _}
  end

  test "a real timeout after submitting generation does not replay the request" do
    port = stalled_server()

    assert_raise RuntimeError, ~r/timeout/, fn ->
      Model.http("http://127.0.0.1:#{port}", "", :post, "/v1/messages", %{}, 100, :stream)
    end

    assert_receive {:peer_received, request}
    assert request =~ "POST /v1/messages HTTP/1.1"
    refute_receive {:retry_wait, _}
  end

  test "another caller's connection failure cannot make an ambiguous generation safe to retry" do
    parent = self()

    Application.put_env(:eab, :http_request, fn _ ->
      Task.async(fn ->
        :telemetry.execute([:finch, :connect, :stop], %{}, %{
          error: %Req.TransportError{reason: :timeout}
        })
      end)
      |> Task.await()

      send(parent, :request)
      {:error, %Req.TransportError{reason: :timeout}}
    end)

    assert_raise RuntimeError, fn -> Model.stream(endpoint("strata"), "", %{}) end
    assert_receive :request
    refute_receive :request
    refute_receive {:retry_wait, _}
  end

  test "observed generation submission prevents replay even for a connection error" do
    parent = self()

    Application.put_env(:eab, :http_request, fn _ ->
      :telemetry.execute([:finch, :send, :start], %{}, %{})
      send(parent, :request)
      {:error, %Req.TransportError{reason: :ehostunreach}}
    end)

    assert_raise RuntimeError, fn -> Model.stream(endpoint("strata"), "", %{}) end
    assert_receive :request
    refute_receive :request
    refute_receive {:retry_wait, _}
  end
end
