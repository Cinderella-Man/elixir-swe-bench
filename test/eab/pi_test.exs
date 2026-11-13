defmodule Eab.PiTest do
  use ExUnit.Case, async: false
  alias Eab.{Command, Model, Pi, PiGateway, Store}

  setup do
    prefix = "runs/pi-test-#{System.unique_integer([:positive])}/case"
    Store.write("#{prefix}/attempt.json", %{})
    Application.put_env(:eab, :http_retry_sleep, fn _ -> :ok end)

    on_exit(fn ->
      Application.delete_env(:eab, :http_request)
      Application.delete_env(:eab, :http_retry_sleep)
      File.rm_rf!(Store.path(Path.dirname(prefix)))
    end)

    %{prefix: prefix}
  end

  defp endpoint(backend),
    do: %{
      "url" => "http://synthetic",
      "backend" => backend,
      "model" => "synthetic-model",
      "context" => 32768
    }

  test "fresh Pi sessions send identical initial prompts and tools", %{prefix: prefix} do
    workspace = Store.path("#{prefix}/workspace")
    File.mkdir_p!(workspace)
    model = %{"backend" => "openai_subscription", "model" => "frozen-model"}
    settings = Eab.OpenAI.settings(%{})

    inputs =
      for attempt <- 1..2 do
        config = Pi.config(model, settings, "Repair the reported defect.", "Preserve behavior.")
        path = "#{prefix}/fresh-#{attempt}.json"
        Store.write(path, config)

        handler = fn
          %{"type" => "request"} = frame, [] ->
            reply = %{
              "id" => frame["id"],
              "status" => 400,
              "content_type" => "application/json",
              "body" => Jason.encode!(%{"error" => %{"message" => "Input captured"}})
            }

            {reply, [Map.take(frame["body"], ~w(model input instructions tools))]}

          %{"type" => "request"}, _ ->
            flunk("Input capture must not retry")

          _, state ->
            {nil, state}
        end

        result =
          Command.exchange(
            "/opt/pi/node",
            ["/opt/pi/bridge.mjs", Store.path(path)],
            [],
            handler,
            cd: workspace,
            timeout: 45
          )

        [input] = result["state"]
        assert Jason.encode!(input) =~ "Repair the reported defect."
        assert input["tools"] != []
        input
      end

    assert Enum.at(inputs, 0) == Enum.at(inputs, 1)
  end

  test "real Pi reconnects during token counting and finishes using both native adapters",
       %{prefix: prefix} do
    parent = self()

    for backend <- ["llama_cpp", "strata"] do
      model = endpoint(backend)
      settings = Model.settings(model)
      path = "#{prefix}/#{backend}"
      workspace = Store.path("#{path}/workspace")
      File.mkdir_p!(workspace)

      config =
        Pi.config(
          model,
          settings,
          "Write repaired.txt containing fixed, then summarize.",
          "Use the write tool."
        )

      Store.write("#{path}/config.json", config)
      counts = :counters.new(1, [])

      Application.put_env(:eab, :http_request, fn opts ->
        payload = opts[:json]

        if String.ends_with?(opts[:url], "tokens") do
          :counters.add(counts, 1, 1)

          if :counters.get(counts, 1) == 1,
            do: {:error, %Req.TransportError{reason: :timeout}},
            else: {:ok, %{status: 200, body: %{"input_tokens" => 42}}}
        else
          send(parent, {:generation, backend, payload})

          tool_done =
            Enum.any?(payload["messages"], fn message ->
              message["role"] == "tool" or
                (is_list(message["content"]) and
                   Enum.any?(message["content"], &(&1["type"] == "tool_result")))
            end)

          {:ok, %{status: 200, body: response(backend, tool_done)}}
        end
      end)

      state = Pi.state(model, "secret", settings, path, fn _ -> :ok end)

      run_id = prefix |> String.split("/") |> Enum.at(1)

      result =
        Eab.Activity.with_case(run_id, backend, "secret", fn ->
          Command.exchange(
            "/opt/pi/node",
            ["/opt/pi/bridge.mjs", Store.path("#{path}/config.json")],
            state,
            &Pi.handle/2,
            cd: workspace,
            timeout: 45
          )
        end)

      assert Pi.finish(result) == %{
               "calls" => 2,
               "generated_tokens" => 24,
               "stop_reason" => "agent_completed",
               "measurement" => %{"attempt_ms" => 0}
             }

      assert File.read!(Path.join(workspace, "repaired.txt")) == "fixed"
      activity = File.read!(Store.path("runs/#{run_id}/#{backend}/activity.log"))
      assert activity =~ "write"
      assert activity =~ "repaired.txt"
      assert activity =~ "Model call 1"
      assert activity =~ "retry 1/5 in 1s"
      assert :counters.get(counts, 1) == 3
      assert_receive {:generation, ^backend, first}

      if backend == "strata" do
        refute Map.has_key?(first, "thinking")
        refute Map.has_key?(first, "output_config")
        refute Map.has_key?(first, "reasoning_budget_tokens")
      end

      assert Jason.encode!(first["messages"]) =~ "Write repaired.txt"
      refute Jason.encode!(first["messages"]) =~ "echo with value ready"
      assert_receive {:generation, ^backend, second}
      assert Jason.encode!(second["messages"]) =~ "repaired.txt"
      assert Jason.encode!(second["messages"]) =~ "Investigating the ticket"
      refute_receive {:generation, ^backend, _}
      assert File.read!(Store.path("#{path}/pi-events.jsonl")) =~ "tool_execution_end"
      refute File.read!(Store.path("#{path}/config.json")) =~ "secret"
    end
  end

  test "cancelling a Pi exchange drains a pending connection retry", %{prefix: prefix} do
    parent = self()
    model = endpoint("strata")
    state = Pi.state(model, "", Model.settings(model), prefix, fn _ -> :ok end)

    Application.put_env(:eab, :http_request, fn _ ->
      send(parent, :request)
      {:error, %Req.TransportError{reason: :timeout}}
    end)

    Application.put_env(:eab, :http_retry_sleep, fn _ ->
      send(parent, {:retry_wait, self()})

      receive do
        :continue -> :ok
      after
        10_000 -> raise "Retry cancellation test watchdog expired"
      end
    end)

    frame = %{
      "type" => "request",
      "id" => "1",
      "method" => "POST",
      "path" => "/v1/messages",
      "body" => %{"messages" => [%{"role" => "user", "content" => "ticket"}]}
    }

    script = "printf '%s\\n' " <> Command.quote(Jason.encode!(frame)) <> "; read reply"

    {owner, monitor} =
      spawn_monitor(fn ->
        Command.exchange("sh", ["-c", script], state, &Pi.handle/2, timeout: 15)
      end)

    on_exit(fn ->
      Process.exit(owner, :kill)
      Command.await_scope(owner)
    end)

    assert_receive :request, 3000
    assert_receive {:retry_wait, callback}, 3000
    callback_monitor = Process.monitor(callback)
    Process.exit(owner, :kill)
    Command.await_owner(owner)
    Command.await_scope(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 3000
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, _}, 3000
    refute_receive :request
  end

  test "real Pi stops at the token budget without retrying and keeps the edited file", %{
    prefix: prefix
  } do
    model = endpoint("llama_cpp")
    settings = Model.settings(model, %{"max_tokens" => 12})
    workspace = Store.path("#{prefix}/workspace")
    File.mkdir_p!(workspace)

    Store.write(
      "#{prefix}/config.json",
      Pi.config(model, settings, "Repair the file.", "Use write.")
    )

    Application.put_env(:eab, :http_request, fn opts ->
      body =
        if String.ends_with?(opts[:url], "tokens"),
          do: %{"input_tokens" => 42},
          else: response("llama_cpp", false)

      {:ok, %{status: 200, body: body}}
    end)

    opts = [cd: workspace, timeout: 45]

    result =
      Command.exchange(
        "/opt/pi/node",
        ["/opt/pi/bridge.mjs", Store.path("#{prefix}/config.json")],
        Pi.state(model, "", settings, prefix, fn _ -> :ok end),
        &Pi.handle/2,
        opts
      )

    assert Pi.finish(result)["stop_reason"] == "token_budget"
    assert Pi.finish(result)["calls"] == 1
    assert Pi.finish(result)["generated_tokens"] == 12
    assert File.read!(Path.join(workspace, "repaired.txt")) == "fixed"
  end

  test "a final reply cut at its allowance records which budget ended the attempt", %{
    prefix: prefix
  } do
    model = endpoint("llama_cpp")
    settings = Model.settings(model, %{"max_tokens" => 100})

    finish = fn last_stop, generated ->
      start = %{
        Pi.state(model, "", settings, prefix, fn _ -> :ok end, false)
        | calls: 3,
          generated_tokens: generated
      }

      state =
        Enum.reduce(
          [
            %{
              "type" => "event",
              "event" => %{
                "type" => "message_end",
                "message" => %{"role" => "assistant", "stopReason" => last_stop}
              }
            },
            %{"type" => "event", "event" => %{"type" => "agent_settled", "aborted" => false}},
            %{"type" => "exit", "code" => 0}
          ],
          start,
          fn frame, state -> elem(Pi.handle(frame, state), 1) end
        )

      Pi.finish(%{"state" => state, "returncode" => 0})["stop_reason"]
    end

    assert finish.("stop", 60) == "agent_completed"
    assert finish.("length", 60) == "response_budget"
    assert finish.("length", 100) == "token_budget"
  end

  test "the bash watchdog kills a command that never exits and Pi continues", %{prefix: prefix} do
    parent = self()
    model = endpoint("llama_cpp")
    settings = Model.settings(model)
    workspace = Store.path("#{prefix}/workspace")
    File.mkdir_p!(workspace)
    config = Pi.config(model, settings, "Run the check.", "Use bash.")
    assert config["settings"]["shellPath"] == "/opt/pi/bash-watchdog.mjs"
    assert config["bash_timeout_seconds"] == 1200
    Store.write("#{prefix}/config.json", %{config | "bash_timeout_seconds" => 3})
    marker = "eab-watchdog-#{System.unique_integer([:positive])}"
    # The livebook-pr-2800 stall: a VM without halt() leaves head waiting for more lines.
    command =
      "echo started; erl -noshell -eval 'io:format(\"ready~n\")' -extra #{marker} | head -5"

    Application.put_env(:eab, :http_request, fn opts ->
      messages = opts[:json]["messages"] || []

      body =
        cond do
          String.ends_with?(opts[:url], "tokens") ->
            %{"input_tokens" => 42}

          tool = Enum.find(messages, &(&1["role"] == "tool")) ->
            send(parent, {:tool_result, Jason.encode!(tool["content"])})
            response("llama_cpp", true)

          true ->
            bash_call(command)
        end

      {:ok, %{status: 200, body: body}}
    end)

    result =
      Command.exchange(
        "/opt/pi/node",
        ["/opt/pi/bridge.mjs", Store.path("#{prefix}/config.json")],
        Pi.state(model, "", settings, prefix, fn _ -> :ok end),
        &Pi.handle/2,
        cd: workspace,
        timeout: 45
      )

    assert Pi.finish(result)["stop_reason"] == "agent_completed"
    assert_receive {:tool_result, output}
    assert output =~ "started"
    assert output =~ "Command timed out after 3 seconds"

    survivors =
      for pid <- File.ls!("/proc"),
          {:ok, cmdline} <- [File.read("/proc/#{pid}/cmdline")],
          cmdline =~ marker,
          do: pid

    assert survivors == []
  end

  test "both adapters continue past 32 calls and stop exactly at the generation budget", %{
    prefix: prefix
  } do
    parent = self()

    for backend <- ["llama_cpp", "strata"] do
      model = endpoint(backend)
      settings = Model.settings(model, %{"max_tokens" => 473, "response_tokens" => 12})

      frame = %{
        "type" => "request",
        "id" => "1",
        "method" => "POST",
        "path" => if(backend == "strata", do: "/v1/messages", else: "/v1/chat/completions"),
        "body" => %{"messages" => [%{"role" => "user", "content" => "ticket"}], "tools" => []}
      }

      Application.put_env(:eab, :http_request, fn opts ->
        if String.ends_with?(opts[:url], "tokens") do
          {:ok, %{status: 200, body: %{"input_tokens" => 42}}}
        else
          allowance = opts[:json]["max_tokens"]
          send(parent, {:allowance, allowance})
          {:ok, %{status: 200, body: response(backend, false, allowance)}}
        end
      end)

      state = Pi.state(model, "", settings, "#{prefix}/#{backend}", fn _ -> :ok end)

      state =
        Enum.reduce(1..40, state, fn call, state ->
          {reply, state} = PiGateway.request(frame, state)
          assert reply["status"] == 200
          assert state.calls == call
          assert state.stop_reason == nil
          assert_receive {:allowance, allowance}
          assert allowance == if(call == 40, do: 5, else: 12)
          state
        end)

      assert state.generated_tokens == 473

      Application.put_env(:eab, :http_request, fn _ ->
        flunk("Exhausted generation budget must prevent network access")
      end)

      {reply, stopped} = PiGateway.request(frame, state)
      assert reply["status"] == 429
      assert stopped.calls == 40
      assert stopped.stop_reason == "token_budget"
    end
  end

  test "budgets stop forwarding, count exact Pi requests and retain endpoint errors", %{
    prefix: prefix
  } do
    model = endpoint("llama_cpp")
    settings = Model.settings(model)

    frame = %{
      "type" => "request",
      "id" => "1",
      "method" => "POST",
      "path" => "/v1/chat/completions",
      "body" => %{"messages" => [%{"role" => "user", "content" => "ticket"}], "tools" => []}
    }

    state = Pi.state(model, "private-key", settings, prefix, fn _ -> :ok end)

    Application.put_env(:eab, :http_request, fn _ ->
      flunk("Budget must prevent network access")
    end)

    {reply, stopped} =
      PiGateway.request(frame, %{state | generated_tokens: settings["max_tokens"]})

    assert reply["status"] == 429
    assert stopped.stop_reason == "token_budget"

    Application.put_env(:eab, :http_request, fn opts ->
      assert String.ends_with?(opts[:url], "input_tokens")
      {:ok, %{status: 200, body: %{"input_tokens" => settings["window_tokens"]}}}
    end)

    {_, stopped} = PiGateway.request(frame, state)
    assert stopped.stop_reason == "context_budget"
    assert stopped.calls == 0

    Application.put_env(:eab, :http_request, fn _ -> raise "server failure private-key" end)
    {reply, failed} = PiGateway.request(frame, state)
    assert reply["status"] == 502
    assert failed.error == "server failure [REDACTED]"
    assert Store.read("#{prefix}/agent-progress.json")["error"] == failed.error
  end

  test "exhausted token-count retries retain the cause without starting generation", %{
    prefix: prefix
  } do
    parent = self()
    model = endpoint("strata")
    state = Pi.state(model, "private-key", Model.settings(model), prefix, fn _ -> :ok end)

    Application.put_env(:eab, :http_request, fn opts ->
      send(parent, {:request, opts[:url]})
      {:error, %Req.TransportError{reason: :timeout}}
    end)

    frame = %{
      "type" => "request",
      "id" => "1",
      "method" => "POST",
      "path" => "/v1/messages",
      "body" => %{"messages" => [%{"role" => "user", "content" => "ticket"}]}
    }

    {reply, failed} = PiGateway.request(frame, state)
    assert reply["status"] == 502
    assert failed.error =~ "count_tokens: timeout"
    refute failed.error =~ "private-key"
    assert failed.calls == 0
    assert failed.generated_tokens == 0
    assert Store.read("#{prefix}/agent-progress.json")["error"] == failed.error
    assert Jason.decode!(reply["body"])["error"]["message"] == failed.error

    for _ <- 1..6,
        do: assert_receive({:request, "http://synthetic/v1/messages/count_tokens"})

    refute_receive {:request, _}

    # Pi cannot retry past exhausted transport retries and start a generation.
    {_, failed_again} = PiGateway.request(frame, failed)
    assert failed_again == failed
    refute_receive {:request, _}
  end

  test "a recovered token count continues the same Pi call and records retries", %{prefix: prefix} do
    parent = self()
    attempts = :counters.new(1, [])
    model = endpoint("strata")
    state = Pi.state(model, "private-key", Model.settings(model), prefix, fn _ -> :ok end)

    Application.put_env(:eab, :http_request, fn opts ->
      send(parent, {:request, opts[:url]})

      if String.ends_with?(opts[:url], "count_tokens") do
        :counters.add(attempts, 1, 1)

        if :counters.get(attempts, 1) == 1,
          do: {:error, %Req.TransportError{reason: :timeout}},
          else: {:ok, %{status: 200, body: %{"input_tokens" => 42}}}
      else
        {:ok, %{status: 200, body: response("strata", true)}}
      end
    end)

    frame = %{
      "type" => "request",
      "id" => "1",
      "method" => "POST",
      "path" => "/v1/messages",
      "body" => %{"messages" => [%{"role" => "user", "content" => "ticket"}]}
    }

    run_id = prefix |> String.split("/") |> Enum.at(1)

    {reply, recovered} =
      Eab.Activity.with_case(run_id, "case", "private-key", fn ->
        PiGateway.request(frame, state)
      end)

    assert reply["status"] == 200
    assert recovered.error == nil
    assert recovered.calls == 1
    assert recovered.generated_tokens == 12
    assert Store.read("#{prefix}/agent-progress.json")["error"] == nil
    assert_receive {:request, "http://synthetic/v1/messages/count_tokens"}
    assert_receive {:request, "http://synthetic/v1/messages/count_tokens"}
    assert_receive {:request, "http://synthetic/v1/messages"}
    refute_receive {:request, _}
    activity = File.read!(Store.path("#{prefix}/activity.log"))
    assert activity =~ "count_tokens: timeout; retry 1/5 in 1s"
    refute activity =~ "private-key"
  end

  test "Pi config cannot inherit credentials, compaction, retries or extra tools" do
    config =
      Pi.config(endpoint("strata"), Model.settings(endpoint("strata")), "ticket", "instructions")

    refute Jason.encode!(config) =~ "http://synthetic"
    assert config["settings"]["compaction"]["enabled"] == false
    assert config["settings"]["retry"]["enabled"] == false
    assert config["settings"]["retry"]["provider"]["maxRetries"] == 0
    assert config["models"]["providers"]["benchmark"]["api"] == "anthropic-messages"
  end

  defp sse(events), do: Enum.map_join(events, fn e -> "data: " <> Jason.encode!(e) <> "\n\n" end)

  defp response(backend, done, tokens \\ 12)

  defp response("llama_cpp", done, tokens) do
    delta =
      if done,
        do: %{"role" => "assistant", "content" => "Done."},
        else: %{
          "role" => "assistant",
          "tool_calls" => [
            %{
              "index" => 0,
              "id" => "call_1",
              "type" => "function",
              "function" => %{
                "name" => "write",
                "arguments" => Jason.encode!(%{"path" => "repaired.txt", "content" => "fixed"})
              }
            }
          ]
        }

    sse([
      %{
        "id" => "synthetic",
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"reasoning_content" => "Investigating the ticket"},
            "finish_reason" => nil
          }
        ]
      },
      %{
        "id" => "synthetic",
        "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => nil}]
      },
      %{
        "id" => "synthetic",
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{},
            "finish_reason" => if(done, do: "stop", else: "tool_calls")
          }
        ],
        "usage" => %{"prompt_tokens" => 42, "completion_tokens" => tokens}
      }
    ]) <> "data: [DONE]\n\n"
  end

  defp response("strata", done, tokens) do
    block =
      if done,
        do: %{"type" => "text", "text" => ""},
        else: %{"type" => "tool_use", "id" => "call_1", "name" => "write", "input" => %{}}

    delta =
      if done,
        do: %{"type" => "text_delta", "text" => "Done."},
        else: %{
          "type" => "input_json_delta",
          "partial_json" => Jason.encode!(%{"path" => "repaired.txt", "content" => "fixed"})
        }

    events = [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "synthetic",
          "type" => "message",
          "role" => "assistant",
          "content" => [],
          "model" => "synthetic-model",
          "usage" => %{"input_tokens" => 42, "output_tokens" => 0}
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
        "delta" => %{"type" => "thinking_delta", "thinking" => "Investigating the ticket"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "content_block_start", "index" => 1, "content_block" => block},
      %{"type" => "content_block_delta", "index" => 1, "delta" => delta},
      %{"type" => "content_block_stop", "index" => 1},
      %{
        "type" => "message_delta",
        "delta" => %{
          "stop_reason" => if(done, do: "end_turn", else: "tool_use"),
          "stop_sequence" => nil
        },
        "usage" => %{
          "input_tokens" => 32,
          "cache_read_input_tokens" => 10,
          "output_tokens" => tokens
        }
      },
      %{"type" => "message_stop"}
    ]

    Enum.map_join(events, fn e -> "event: " <> e["type"] <> "\n" <> sse([e]) end)
  end

  defp bash_call(command) do
    call = %{
      "index" => 0,
      "id" => "call_1",
      "type" => "function",
      "function" => %{"name" => "bash", "arguments" => Jason.encode!(%{"command" => command})}
    }

    sse([
      %{
        "id" => "synthetic",
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"role" => "assistant", "tool_calls" => [call]},
            "finish_reason" => nil
          }
        ]
      },
      %{
        "id" => "synthetic",
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}],
        "usage" => %{"prompt_tokens" => 42, "completion_tokens" => 12}
      }
    ]) <> "data: [DONE]\n\n"
  end
end
