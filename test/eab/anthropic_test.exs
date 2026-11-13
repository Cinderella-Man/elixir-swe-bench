defmodule Eab.AnthropicTest do
  use ExUnit.Case, async: false
  alias Eab.{Anthropic, Command, Model, Pi, PiGateway, Store}

  @key "sk-ant-api-test-secret"
  @row %{
    "id" => "claude-haiku-5-5",
    "display_name" => "Claude Haiku 5.5",
    "max_input_tokens" => 1_000_000,
    "max_tokens" => 128_000,
    "adaptive_thinking" => true,
    "efforts" => ~w(low medium high xhigh max)
  }

  setup do
    prefix = "runs/anthropic-test-#{System.unique_integer([:positive])}/case"
    Store.write("#{prefix}/attempt.json", %{})
    Application.put_env(:eab, :http_retry_sleep, fn _ -> :ok end)

    on_exit(fn ->
      Application.delete_env(:eab, :http_request)
      Application.delete_env(:eab, :http_retry_sleep)
      File.rm_rf!(Store.path(Path.dirname(prefix)))
    end)

    %{prefix: prefix, endpoint: Anthropic.endpoint(@row)}
  end

  test "catalog reads effort capabilities and sends the key only to the official endpoint", f do
    parent = self()

    Application.put_env(:eab, :http_request, fn opts ->
      send(parent, {:request, opts})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => [
             %{
               "id" => "claude-haiku-5-5",
               "display_name" => "Claude Haiku 5.5",
               "max_input_tokens" => 1_000_000,
               "max_tokens" => 128_000,
               "capabilities" => %{
                 "thinking" => %{"types" => %{"adaptive" => %{"supported" => true}}},
                 "effort" => %{
                   "supported" => true,
                   "low" => %{"supported" => true},
                   "medium" => %{"supported" => true},
                   "high" => %{"supported" => true},
                   "xhigh" => %{"supported" => true},
                   "max" => %{"supported" => true}
                 }
               }
             },
             %{"id" => "claude-haiku-4-5", "display_name" => "Claude Haiku 4.5"}
           ]
         }
       }}
    end)

    assert [haiku, older] = Anthropic.catalog(@key)
    assert haiku == @row
    assert older["efforts"] == [] and older["adaptive_thinking"] == false
    assert_receive {:request, opts}
    assert opts[:url] == "https://api.anthropic.com/v1/models?limit=100"
    assert opts[:headers] == [{"x-api-key", @key}, {"anthropic-version", "2023-06-01"}]
    assert opts[:retry] == false and opts[:redirect] == false
    assert Anthropic.endpoint?("https://api.anthropic.com/v1/")
    refute Anthropic.endpoint?("https://api.anthropic.com.attacker/v1")
    assert Eab.ModelIdentity.label(f.endpoint) == "Claude Haiku 5.5"

    assert_raise RuntimeError, ~r/only be sent/, fn ->
      Anthropic.stream(Map.put(f.endpoint, "url", "https://attacker"), @key, %{})
    end

    refute_receive {:request, _}
  end

  test "settings default to a soft threshold, the model's longest reply and a supported effort",
       f do
    settings = Model.settings(f.endpoint)
    assert settings["max_tokens"] == 262_144
    assert settings["response_tokens"] == 128_000
    assert settings["window_tokens"] == 1_000_000
    assert settings["reasoning_effort"] == "high"
    assert settings["budget_policy"] == "response_boundary_soft_limit"
    assert is_nil(settings["seed"])

    assert Model.settings(f.endpoint, %{"reasoning_effort" => "xhigh", "response_tokens" => ""})[
             "reasoning_effort"
           ] == "xhigh"

    assert_raise ArgumentError, ~r/does not support max/, fn ->
      Model.settings(put_in(f.endpoint, ["profile", "efforts"], ~w(low high)), %{
        "reasoning_effort" => "max"
      })
    end

    assert_raise ArgumentError, fn ->
      Model.settings(f.endpoint, %{"response_tokens" => "200000"})
    end
  end

  test "real pinned Pi replays signed thinking and tool calls with frozen effort", f do
    parent = self()

    Application.put_env(:eab, :http_request, fn opts ->
      assert opts[:url] == "https://api.anthropic.com/v1/messages"
      assert {"x-api-key", @key} in opts[:headers]
      send(parent, {:generation, opts[:json]})

      done =
        Enum.any?(opts[:json]["messages"], fn message ->
          is_list(message["content"]) and
            Enum.any?(message["content"], &(&1["type"] == "tool_result"))
        end)

      # Exercise streamed Req chunks, not just a ready-made body.
      response =
        response(done)
        |> String.graphemes()
        |> Enum.chunk_every(61)
        |> Enum.reduce(%Req.Response{status: 200}, fn chars, resp ->
          {:cont, {_, resp}} = opts[:into].({:data, Enum.join(chars)}, {nil, resp})
          resp
        end)

      {:ok, response}
    end)

    workspace = Store.path("#{f.prefix}/workspace")
    File.mkdir_p!(workspace)
    settings = Model.settings(f.endpoint, %{"reasoning_effort" => "xhigh"})

    config =
      Pi.config(
        f.endpoint,
        settings,
        "Write repaired.txt containing fixed, then summarize.",
        "Use the write tool."
      )

    Store.write("#{f.prefix}/config.json", config)
    state = Pi.state(f.endpoint, @key, settings, f.prefix, fn _ -> :ok end)

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
             "stop_reason" => "agent_completed",
             "measurement" => %{"attempt_ms" => 0}
           }

    assert File.read!(Path.join(workspace, "repaired.txt")) == "fixed"
    assert_receive {:generation, first}
    assert first["model"] == "claude-haiku-5-5" and first["stream"] == true
    assert first["max_tokens"] == 128_000
    assert first["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
    assert first["output_config"]["effort"] == "xhigh"
    assert Enum.any?(first["tools"], &(&1["name"] == "write"))
    assert Jason.encode!(first) =~ "cache_control"
    for key <- ~w(temperature top_p top_k metadata), do: refute(Map.has_key?(first, key))

    assert_receive {:generation, second}
    assistant = Enum.find(second["messages"], &(&1["role"] == "assistant"))

    assert %{"type" => "thinking", "thinking" => "Plan the repair", "signature" => "sig-test"} in assistant[
             "content"
           ]

    assert Enum.any?(assistant["content"], &(&1["type"] == "tool_use" and &1["id"] == "toolu_1"))
    assert Jason.encode!(second["messages"]) =~ "Write repaired.txt"
    refute_receive {:generation, _}

    assert Store.read("#{f.prefix}/usage-0000.json") == %{
             "input_tokens" => 42,
             "output_tokens" => 12,
             "uncached_input_tokens" => 30,
             "cache_creation_input_tokens" => 10,
             "cache_read_input_tokens" => 2,
             "stop_reason" => "tool_use"
           }

    for file <- Path.wildcard(Store.path("#{f.prefix}/*")),
        File.regular?(file),
        do: refute(File.read!(file) =~ @key)
  end

  test "busy responses retry before generation; provider errors keep evidence without the key",
       f do
    parent = self()
    counts = :counters.new(1, [])

    Application.put_env(:eab, :http_request, fn _ ->
      :counters.add(counts, 1, 1)
      send(parent, :request)

      case :counters.get(counts, 1) do
        1 ->
          {:ok, %{status: 529, headers: %{"retry-after" => ["3"]}, body: "{}"}}

        2 ->
          {:ok, %{status: 200, body: response(true)}}

        _ ->
          {:ok,
           %{
             status: 400,
             headers: %{"request-id" => ["req_test"]},
             body:
               Jason.encode!(%{
                 "type" => "error",
                 "error" => %{
                   "type" => "invalid_request_error",
                   "message" => "bad history for #{@key}"
                 }
               })
           }}
      end
    end)

    Application.put_env(:eab, :http_retry_sleep, fn delay -> send(parent, {:slept, delay}) end)
    state = Pi.state(f.endpoint, @key, Model.settings(f.endpoint), f.prefix, fn _ -> :ok end)
    {reply, state} = PiGateway.request(frame(), state)
    assert reply["status"] == 200
    assert_receive {:slept, 3_000}
    assert state.calls == 1 and state.generated_tokens == 12

    {reply, state} = PiGateway.request(frame(), state)
    assert reply["status"] == 502
    assert state.error =~ "invalid_request_error"
    refute state.error =~ @key
    details = Store.read("#{f.prefix}/provider-error.json")
    assert details["status"] == 400 and details["request_id"] == "req_test"
    refute Jason.encode!(details) =~ @key
    assert :counters.get(counts, 1) == 3
  end

  test "soft threshold allows the whole response then stops before the next request", f do
    Application.put_env(:eab, :http_request, fn _ ->
      {:ok, %{status: 200, body: response(false)}}
    end)

    settings = Model.settings(f.endpoint, %{"max_tokens" => 5})
    state = Pi.state(f.endpoint, @key, settings, f.prefix, fn _ -> :ok end)
    {reply, state} = PiGateway.request(frame(), state)
    assert reply["status"] == 200 and state.generated_tokens == 12
    {reply, state} = PiGateway.request(frame(), state)
    assert reply["status"] == 429
    assert state.stop_reason == "token_budget"
  end

  test "stream errors and missing completion markers are attempt errors" do
    overloaded =
      sse([
        %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 1}}},
        %{
          "type" => "error",
          "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
        }
      ])

    assert_raise Anthropic.Error, ~r/overloaded_error/, fn -> Anthropic.usage(overloaded) end

    assert_raise RuntimeError, ~r/message_stop/, fn ->
      Anthropic.usage(String.replace(response(true), ~s("message_stop"), ~s("other")))
    end
  end

  defp frame,
    do: %{
      "type" => "request",
      "id" => "1",
      "method" => "POST",
      "path" => "/v1/messages",
      "body" => %{"messages" => [%{"role" => "user", "content" => "ticket"}]}
    }

  defp sse(events),
    do: Enum.map_join(events, fn e -> "event: #{e["type"]}\ndata: #{Jason.encode!(e)}\n\n" end)

  defp response(done) do
    {block, delta} =
      if done,
        do: {%{"type" => "text", "text" => ""}, %{"type" => "text_delta", "text" => "Done."}},
        else:
          {%{"type" => "tool_use", "id" => "toolu_1", "name" => "write", "input" => %{}},
           %{
             "type" => "input_json_delta",
             "partial_json" => Jason.encode!(%{"path" => "repaired.txt", "content" => "fixed"})
           }}

    sse([
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_test",
          "type" => "message",
          "role" => "assistant",
          "content" => [],
          "model" => "claude-haiku-5-5",
          "usage" => %{
            "input_tokens" => 30,
            "cache_creation_input_tokens" => 10,
            "cache_read_input_tokens" => 2,
            "output_tokens" => 1
          }
        }
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => "", "signature" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "Plan the repair"}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "signature_delta", "signature" => "sig-test"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "content_block_start", "index" => 1, "content_block" => block},
      %{"type" => "content_block_delta", "index" => 1, "delta" => delta},
      %{"type" => "content_block_stop", "index" => 1},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => if(done, do: "end_turn", else: "tool_use")},
        "usage" => %{"output_tokens" => 12}
      },
      %{"type" => "message_stop"}
    ])
  end
end
