defmodule Eab.OpenAITest do
  use ExUnit.Case, async: false
  alias Eab.{ChatGPTFixture, Command, Model, OpenAI, Pi, PiGateway, Store}

  setup do
    f = ChatGPTFixture.start!()
    id = ChatGPTFixture.login!(f)
    prefix = "runs/openai-test-#{System.unique_integer([:positive])}/case"
    Store.write("#{prefix}/attempt.json", %{})
    on_exit(fn -> File.rm_rf!(Store.path(Path.dirname(prefix))) end)

    Map.merge(f, %{
      endpoint:
        OpenAI.endpoint(id, %{"slug" => "synthetic-model", "display_name" => "Synthetic"}),
      prefix: prefix
    })
  end

  test "uses account-visible catalog order and only sends bearer to the official endpoint", f do
    parent = self()

    Application.put_env(:eab, :http_request, fn opts ->
      send(parent, {:inference, opts})

      {:ok,
       %{
         status: 200,
         body: %{
           "models" => [
             %{"slug" => "b", "display_name" => "B", "visibility" => "list"},
             %{"slug" => "hidden", "visibility" => "hide"},
             %{"slug" => "a", "display_name" => "A", "visibility" => "list"}
           ]
         }
       }}
    end)

    assert Enum.map(OpenAI.catalog("oaiapp_test"), & &1["slug"]) == ["b", "a"]
    assert_receive {:inference, opts}
    assert opts[:url] == "https://api.openai.com/v1/models"
    assert opts[:headers] == [{"authorization", "Bearer access-test-0"}]
    assert opts[:retry] == false and opts[:redirect] == false
    assert OpenAI.endpoint?("https://api.openai.com/v1/")
    refute OpenAI.endpoint?("https://api.openai.com.attacker/v1")

    assert_raise RuntimeError, ~r/only be sent/, fn ->
      OpenAI.stream(Map.put(f.endpoint, "url", "https://attacker"), %{})
    end

    refute_receive {:inference, _}
  end

  test "real pinned Pi preserves tool IDs, namespaced calls, full history and encrypted reasoning",
       f do
    parent = self()

    Application.put_env(:eab, :http_request, fn opts ->
      assert opts[:url] == "https://api.openai.com/v1/responses"
      send(parent, {:generation, opts[:json]})
      done = Enum.any?(opts[:json]["input"], &(&1["type"] == "function_call_output"))
      body = response(done)
      # Exercise streamed Req chunks, not just a ready-made body.
      response =
        Enum.reduce(
          String.graphemes(body) |> Enum.chunk_every(61),
          %Req.Response{status: 200},
          fn chars, resp ->
            {:cont, {_, resp}} = opts[:into].({:data, Enum.join(chars)}, {nil, resp})
            resp
          end
        )

      {:ok, response}
    end)

    workspace = Store.path("#{f.prefix}/workspace")
    File.mkdir_p!(workspace)
    settings = Model.settings(f.endpoint)

    config =
      Pi.config(
        f.endpoint,
        settings,
        "Write repaired.txt containing fixed, then summarize.",
        "Use the write tool."
      )

    Store.write("#{f.prefix}/config.json", config)
    state = Pi.state(f.endpoint, "", settings, f.prefix, fn _ -> :ok end)

    result =
      Command.exchange(
        "/opt/pi/node",
        ["/opt/pi/bridge.mjs", Store.path("#{f.prefix}/config.json")],
        state,
        &Pi.handle/2,
        cd: workspace,
        timeout: 45
      )

    assert Pi.finish(result) == %{
             "calls" => 2,
             "generated_tokens" => 24,
             # Each call: a 42-token prompt and a 12-token reply.
             "peak_context_tokens" => 54,
             "stop_reason" => "agent_completed",
             "measurement" => %{"attempt_ms" => 0}
           }

    assert File.read!(Path.join(workspace, "repaired.txt")) == "fixed"
    assert_receive {:generation, first}
    assert first["store"] == false and first["stream"] == true
    assert first["reasoning"] == %{"effort" => "high", "summary" => "auto"}
    assert first["include"] == ["reasoning.encrypted_content"]
    assert [%{"type" => "namespace", "name" => "functions", "tools" => tools}] = first["tools"]
    assert Enum.any?(tools, &(&1["name"] == "write"))

    for key <-
          ~w(max_output_tokens max_tokens seed temperature top_p previous_response_id prompt_cache_retention),
        do: refute(Map.has_key?(first, key))

    assert_receive {:generation, second}

    assert Enum.find(second["input"], &(&1["type"] == "function_call")) == %{
             "type" => "function_call",
             "id" => "fc_write",
             "call_id" => "call_write",
             "namespace" => "functions",
             "name" => "write",
             "arguments" => Jason.encode!(%{"path" => "repaired.txt", "content" => "fixed"})
           }

    assert Enum.any?(
             second["input"],
             &(&1["type"] == "function_call_output" and &1["call_id"] == "call_write")
           )

    assert Enum.any?(
             second["input"],
             &(&1["type"] == "reasoning" and &1["encrypted_content"] == "encrypted-history-test")
           )

    assert Jason.encode!(second["input"]) =~ "Write repaired.txt"

    for file <- Path.wildcard(Store.path("#{f.prefix}/*")), File.regular?(file) do
      refute File.read!(file) =~ "access-test"
      refute File.read!(file) =~ "refresh-test"
    end
  end

  test "soft threshold allows the whole response then stops before the next request", f do
    parent = self()

    Application.put_env(:eab, :http_request, fn opts ->
      send(parent, {:generation, opts[:json]})
      {:ok, %{status: 200, body: response(false)}}
    end)

    settings = Model.settings(f.endpoint, %{"max_tokens" => 5})
    state = Pi.state(f.endpoint, "", settings, f.prefix, fn _ -> :ok end)
    {reply, state} = PiGateway.request(frame(), state)
    assert reply["status"] == 200
    assert state.generated_tokens == 12
    assert state.calls == 1
    assert state.error == nil
    {reply, state} = PiGateway.request(frame(), state)
    assert reply["status"] == 429
    assert state.stop_reason == "token_budget"
    assert_receive {:generation, _}
    refute_receive {:generation, _}
    assert settings["budget_policy"] == "response_boundary_soft_limit"

    assert is_nil(settings["window_tokens"]) and is_nil(settings["response_tokens"]) and
             is_nil(settings["seed"])
  end

  test "late quota errors, incomplete responses, missing usage and transport failures are errors",
       f do
    failed = %{
      "type" => "response.failed",
      "response" => %{"error" => %{"code" => "subscription_sharing_usage_limit_exceeded"}}
    }

    completed = %{"type" => "response.completed", "response" => %{"status" => "completed"}}

    error =
      assert_raise Eab.OpenAI.Error, fn ->
        OpenAI.usage(%{body: sse([failed]), status: 200, request_id: "req_late"})
      end

    assert error.request_id == "req_late"
    assert error.status == 200

    for body <- [
          sse([failed]),
          response(true) <> sse([failed]),
          sse([%{"type" => "response.incomplete"}]),
          sse([completed]),
          "data: [DONE]\n\n"
        ] do
      Eab.ChatGPTAuth.retry_requests("oaiapp_test")
      Application.put_env(:eab, :http_request, fn _ -> {:ok, %{status: 200, body: body}} end)
      state = Pi.state(f.endpoint, "", Model.settings(f.endpoint), f.prefix, fn _ -> :ok end)
      {reply, state} = PiGateway.request(frame(), state)
      assert reply["status"] == 502
      assert is_binary(state.error)
      assert is_nil(state.stop_reason)
      assert state.generated_tokens == 0
    end

    Eab.ChatGPTAuth.retry_requests("oaiapp_test")
    parent = self()

    Application.put_env(:eab, :http_request, fn _ ->
      send(parent, :sent)
      {:error, %Req.TransportError{reason: :timeout}}
    end)

    assert_raise RuntimeError, ~r/not replayed/, fn -> OpenAI.stream(f.endpoint, %{}) end
    assert_receive :sent
    refute_receive :sent
  end

  test "responses reject malformed reasoning usage and redact echoed credentials", f do
    body = String.replace(response(true), "\"reasoning_tokens\":3", "\"reasoning_tokens\":13")
    assert_raise RuntimeError, ~r/invalid usage/, fn -> OpenAI.usage(body) end

    Application.put_env(:eab, :http_request, fn _ ->
      {:ok, %{status: 200, body: String.replace(response(true), "Done.", "access-test-0")}}
    end)

    refute OpenAI.stream(f.endpoint, %{}).body =~ "access-test"
  end

  test "quota errors preserve provider evidence and pause further requests until explicit reconnect",
       f do
    parent = self()

    Application.put_env(:eab, :http_request, fn _ ->
      send(parent, :generation_sent)

      {:ok,
       %{
         status: 429,
         headers: %{"x-request-id" => ["req_test"]},
         body:
           Jason.encode!(%{
             "error" => %{
               "code" => "subscription_sharing_usage_limit_exceeded",
               "param" => "model",
               "message" => "access-test-0"
             }
           })
       }}
    end)

    state = Pi.state(f.endpoint, "", Model.settings(f.endpoint), f.prefix, fn _ -> :ok end)
    {reply, failed} = PiGateway.request(frame(), state)
    assert reply["status"] == 502
    assert failed.error =~ "Requests are paused"
    evidence = Store.read("#{f.prefix}/provider-error-0000.json")
    assert evidence["status"] == 429
    assert evidence["code"] == "subscription_sharing_usage_limit_exceeded"
    assert evidence["request_id"] == "req_test"
    assert evidence["param"] == "model"
    refute Jason.encode!(evidence) =~ "access-test"
    assert_receive :generation_sent
    {_, failed} = PiGateway.request(frame(), state)
    assert failed.error =~ "Reconnect explicitly"
    refute_receive :generation_sent
    # Quota pauses generation, not identity checks needed by already submitted repairs.
    assert {:ok, "access-test-0"} = Eab.ChatGPTAuth.token("oaiapp_test")
    assert :ok = Eab.ChatGPTAuth.retry_requests("oaiapp_test")
    PiGateway.request(frame(), state)
    assert_receive :generation_sent
  end

  test "direct-admission diagnostic bodies and request IDs survive without leaking credentials",
       f do
    Application.put_env(:eab, :http_request, fn _ ->
      {:ok,
       %{
         status: 403,
         headers: %{"x-request-id" => ["req_region"]},
         body: %{"detail" => "region unavailable access-test-0"}
       }}
    end)

    error = assert_raise Eab.OpenAI.Error, fn -> OpenAI.stream(f.endpoint, %{}) end
    assert error.status == 403
    assert error.request_id == "req_region"
    assert error.body == %{"detail" => "region unavailable [REDACTED]"}
  end

  defp frame,
    do: %{
      "id" => "1",
      "method" => "POST",
      "path" => "/v1/responses",
      "body" => %{"input" => [%{"role" => "user", "content" => "Fix it"}]}
    }

  defp response(done) do
    reasoning = %{
      "type" => "reasoning",
      "id" => "rs_reasoning",
      "summary" => [%{"type" => "summary_text", "text" => "Investigating the ticket"}],
      "encrypted_content" => "encrypted-history-test"
    }

    item =
      if done do
        %{
          "type" => "message",
          "id" => "msg_final",
          "role" => "assistant",
          "status" => "completed",
          "phase" => "final_answer",
          "content" => [%{"type" => "output_text", "text" => "Done.", "annotations" => []}]
        }
      else
        %{
          "type" => "function_call",
          "id" => "fc_write",
          "call_id" => "call_write",
          "namespace" => "functions",
          "name" => "write",
          "arguments" => Jason.encode!(%{"path" => "repaired.txt", "content" => "fixed"})
        }
      end

    response = %{
      "id" => "resp_test",
      "status" => "completed",
      "output" => [reasoning, item],
      "usage" => %{
        "input_tokens" => 42,
        "output_tokens" => 12,
        "total_tokens" => 54,
        "input_tokens_details" => %{"cached_tokens" => 10},
        "output_tokens_details" => %{"reasoning_tokens" => 3}
      }
    }

    sse([
      %{"type" => "response.created", "response" => Map.put(response, "status", "in_progress")},
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => reasoning},
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => reasoning},
      %{
        "type" => "response.output_item.added",
        "output_index" => 1,
        "item" => if(done, do: item, else: Map.put(item, "arguments", ""))
      },
      %{"type" => "response.output_item.done", "output_index" => 1, "item" => item},
      %{"type" => "response.completed", "response" => response}
    ])
  end

  defp sse(events),
    do: Enum.map_join(events, fn event -> "data: " <> Jason.encode!(event) <> "\n\n" end)
end
