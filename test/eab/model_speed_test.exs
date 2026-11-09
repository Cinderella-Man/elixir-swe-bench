defmodule Eab.ModelSpeedTest do
  use ExUnit.Case, async: false
  alias Eab.{Model, ModelSpeed, Pi, PiGateway, Store}

  setup do
    clock = Application.fetch_env!(:eab, :measurement_clock)
    counter = :counters.new(1, [])
    Application.put_env(:eab, :measurement_clock, fn -> :counters.get(counter, 1) end)
    prefix = "runs/model-speed-#{System.unique_integer([:positive])}/case"

    on_exit(fn ->
      Application.put_env(:eab, :measurement_clock, clock)
      Application.delete_env(:eab, :http_request)
      File.rm_rf!(Store.path(Path.dirname(prefix)))
    end)

    %{counter: counter, prefix: prefix}
  end

  defp model(backend),
    do: %{
      "backend" => backend,
      "model" => "fixture",
      "url" => "http://synthetic",
      "context" => 32768
    }

  defp frame(path),
    do: %{
      "type" => "request",
      "id" => "1",
      "method" => "POST",
      "path" => path,
      "body" => %{"messages" => []}
    }

  defp sse(events), do: Enum.map_join(events, "", &"data: #{Jason.encode!(&1)}\n\n")

  defp llama(prompt, timings) do
    sse([
      %{"choices" => [%{"delta" => %{"content" => "Done."}, "finish_reason" => nil}]},
      %{
        "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => prompt, "completion_tokens" => timings["predicted_n"]},
        "timings" => timings
      }
    ]) <> "data: [DONE]\n\n"
  end

  defp finish(state),
    do:
      Pi.finish(%{
        "state" => %{state | assistant: true, settled: true, exit_code: 0},
        "returncode" => 0
      })

  test "llama.cpp's own timings become each call's speed and add up per attempt", %{
    prefix: prefix
  } do
    timings = [
      %{"prompt_n" => 1000, "prompt_ms" => 2000.0, "predicted_n" => 50, "predicted_ms" => 1000.0},
      %{
        "prompt_n" => 200,
        "prompt_ms" => 400.0,
        "predicted_n" => 150,
        "predicted_ms" => 3000.0,
        "draft_n" => 100,
        "draft_n_accepted" => 40
      }
    ]

    calls = :counters.new(1, [])

    Application.put_env(:eab, :http_request, fn opts ->
      if String.ends_with?(opts[:url], "tokens") do
        {:ok, %{status: 200, body: %{"input_tokens" => 42}}}
      else
        :counters.add(calls, 1, 1)
        {:ok, %{status: 200, body: llama(42, Enum.at(timings, :counters.get(calls, 1) - 1))}}
      end
    end)

    model = model("llama_cpp")
    state = Pi.state(model, "", Model.settings(model), prefix, fn _ -> :ok end)
    {%{"status" => 200}, state} = PiGateway.request(frame("/v1/chat/completions"), state)
    {%{"status" => 200}, state} = PiGateway.request(frame("/v1/chat/completions"), state)

    assert Store.read("#{prefix}/usage-0000.json")["speed"] == %{
             "source" => "server_reported",
             "prompt_tokens" => 1000,
             "prompt_ms" => 2000.0,
             "generated_tokens" => 50,
             "generation_ms" => 1000.0
           }

    speed = %{
      "source" => "server_reported",
      "calls" => 2,
      "prompt_tokens" => 1200,
      "prompt_ms" => 2400.0,
      "generated_tokens" => 200,
      "generation_ms" => 4000.0,
      "draft_tokens" => 100,
      "draft_accepted" => 40
    }

    assert Store.read("#{prefix}/agent-progress.json")["measurement"]["model_speed"] == speed
    assert finish(state)["measurement"] == %{"attempt_ms" => 0, "model_speed" => speed}

    assert ModelSpeed.label(speed) ==
             "generation 50.0 tok/s · prompt 500.0 tok/s · 40% of draft tokens accepted · " <>
               "reported by llama.cpp over 2 model calls"
  end

  test "the controller times Strata from request to its first and last token events", %{
    counter: counter,
    prefix: prefix
  } do
    Application.put_env(:eab, :http_request, fn opts ->
      if String.ends_with?(opts[:url], "tokens") do
        {:ok, %{status: 200, body: %{"input_tokens" => 300}}}
      else
        # The request left at 1000 ms; tokens arrive at 1400 and 2400 ms.
        chunks = [
          {1300,
           %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 300}}}},
          {1400, %{"type" => "content_block_delta", "delta" => %{"text" => "Do"}}},
          {2400, %{"type" => "content_block_delta", "delta" => %{"text" => "ne."}}},
          {2500,
           %{
             "type" => "message_delta",
             "usage" => %{
               "input_tokens" => 1,
               "cache_creation_input_tokens" => 199,
               "cache_read_input_tokens" => 100,
               "output_tokens" => 11
             }
           }},
          {2500, %{"type" => "message_stop"}}
        ]

        {:cont, {_, response}} =
          Enum.reduce(chunks, {:cont, {nil, %Req.Response{status: 200}}}, fn {at, event},
                                                                             {:cont, acc} ->
            :counters.put(counter, 1, at)
            opts[:into].({:data, sse([event])}, acc)
          end)

        {:ok, response}
      end
    end)

    model = model("strata")
    state = Pi.state(model, "", Model.settings(model), prefix, fn _ -> :ok end)
    :counters.put(counter, 1, 1000)
    {%{"status" => 200}, state} = PiGateway.request(frame("/v1/messages"), state)

    speed = %{
      "source" => "controller_timed",
      "prompt_tokens" => 200,
      "prompt_ms" => 400,
      "generated_tokens" => 10,
      "generation_ms" => 1000
    }

    assert Store.read("#{prefix}/usage-0000.json")["speed"] == speed
    assert finish(state)["measurement"]["model_speed"] == Map.put(speed, "calls", 1)

    assert ModelSpeed.label(Map.put(speed, "calls", 1)) ==
             "generation 10.0 tok/s · prompt 500.0 tok/s · " <>
               "timed by the controller, network included over 1 model call"
  end

  test "attempts without elapsed time record no speed", %{prefix: prefix} do
    Application.put_env(:eab, :http_request, fn opts ->
      if String.ends_with?(opts[:url], "tokens"),
        do: {:ok, %{status: 200, body: %{"input_tokens" => 42}}},
        else:
          {:ok,
           %{
             status: 200,
             body:
               llama(42, %{
                 "prompt_n" => 42,
                 "prompt_ms" => 100.0,
                 "predicted_n" => 5,
                 "predicted_ms" => 100.0
               })
           }}
    end)

    model = model("llama_cpp")
    state = Pi.state(model, "", Model.settings(model), prefix, fn _ -> :ok end, false)
    {%{"status" => 200}, state} = PiGateway.request(frame("/v1/chat/completions"), state)

    refute Map.has_key?(Store.read("#{prefix}/usage-0000.json"), "speed")
    refute Map.has_key?(finish(state)["measurement"], "model_speed")
  end

  test "a run's speed adds up its measured attempts" do
    speed = fn source, ms ->
      %{
        "source" => source,
        "calls" => 2,
        "prompt_tokens" => 100,
        "prompt_ms" => ms,
        "generated_tokens" => 100,
        "generation_ms" => ms
      }
    end

    run = %{
      "attempts" => %{
        "a" => %{
          "measurement" => %{"attempt_ms" => 1, "model_speed" => speed.("server_reported", 1000)}
        },
        "b" => %{
          "measurement" => %{"attempt_ms" => 1, "model_speed" => speed.("server_reported", 3000)}
        },
        "c" => %{"measurement" => %{"not_measured" => "parallel"}},
        "d" => %{}
      }
    }

    assert ModelSpeed.label(ModelSpeed.of_run(run)) ==
             "generation 50.0 tok/s · prompt 50.0 tok/s · reported by llama.cpp over 4 model calls"

    mixed =
      put_in(run, ["attempts", "b", "measurement", "model_speed", "source"], "controller_timed")

    assert ModelSpeed.of_run(mixed)["source"] == "mixed"
    assert ModelSpeed.of_run(%{"attempts" => %{"c" => %{}}}) == nil
    assert ModelSpeed.label(nil) == "Not measured"
  end
end
