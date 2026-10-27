defmodule Eab.MeasurementTest do
  use ExUnit.Case, async: false
  alias Eab.Measurement

  setup do
    clock = Application.fetch_env!(:eab, :measurement_clock)
    on_exit(fn -> Application.put_env(:eab, :measurement_clock, clock) end)
  end

  test "every attempt records elapsed time without a configuration flag" do
    counter = :counters.new(1, [])
    Application.put_env(:eab, :measurement_clock, fn -> :counters.get(counter, 1) end)
    :counters.put(counter, 1, 100)
    measurement = Measurement.start()
    :counters.put(counter, 1, 1600)
    result = Measurement.finish(measurement)
    assert result == %{"attempt_ms" => 1500}

    assert Eab.Evidence.compact(%{"status" => "completed", "measurement" => result})[
             "measurement"
           ] == result
  end

  test "a run with several parallel attempts records no elapsed time" do
    counter = :counters.new(1, [])
    Application.put_env(:eab, :measurement_clock, fn -> :counters.get(counter, 1) end)
    model = %{"backend" => "llama_cpp", "context" => 32768}
    prefix = "runs/parallel-time-#{System.unique_integer([:positive])}/case"
    on_exit(fn -> File.rm_rf!(Eab.Store.path(Path.dirname(prefix))) end)

    state =
      Eab.Pi.state(model, "", Eab.Model.settings(model), prefix, fn _ -> :ok end, false)

    state = %{state | calls: 1, assistant: true, settled: true, exit_code: 0}
    :counters.put(counter, 1, 9000)
    result = Eab.Pi.finish(%{"state" => state, "returncode" => 0})
    refute Map.has_key?(result["measurement"], "attempt_ms")
    assert Measurement.label(result["measurement"]) =~ "several attempts at once"
    refute Eab.Store.read("#{prefix}/agent-progress.json")["measurement"]["attempt_ms"]
  end

  test "completion freezes time before grading and preserves it on a grading error" do
    alias Eab.{Agent, Model, Pi, Store}
    prefix = "runs/finished-time-#{System.unique_integer([:positive])}/case"
    on_exit(fn -> File.rm_rf!(Store.path(Path.dirname(prefix))) end)
    counter = :counters.new(1, [])
    Application.put_env(:eab, :measurement_clock, fn -> :counters.get(counter, 1) end)
    model = %{"backend" => "llama_cpp", "context" => 32768}
    state = Pi.state(model, "", Model.settings(model), prefix, fn _ -> :ok end)

    state = %{
      state
      | calls: 2,
        generated_tokens: 24,
        assistant: true,
        settled: true,
        exit_code: 0
    }

    :counters.put(counter, 1, 1500)
    result = Pi.finish(%{"state" => state, "returncode" => 0})
    assert result["measurement"] == %{"attempt_ms" => 1500}
    Store.write("#{prefix}/attempt.json", Map.put(result, "status", "grading"))
    :counters.put(counter, 1, 9000)
    run_id = prefix |> String.split("/") |> Enum.at(1)
    failed_grade = Agent.error("case", run_id, "grading failed", "")
    assert failed_grade["measurement"] == %{"attempt_ms" => 1500}
  end

  test "gateway and Pi persist final durations on errors without measuring real time" do
    alias Eab.{Agent, Model, Pi, PiGateway, Store}
    prefix = "runs/measured-test-#{System.unique_integer([:positive])}/case"
    counter = :counters.new(1, [])
    Application.put_env(:eab, :measurement_clock, fn -> :counters.get(counter, 1) end)

    on_exit(fn ->
      Application.delete_env(:eab, :http_request)
      File.rm_rf!(Store.path(Path.dirname(prefix)))
    end)

    model = %{
      "backend" => "strata",
      "model" => "fixture",
      "url" => "http://synthetic",
      "context" => 32768
    }

    state = Pi.state(model, "", Model.settings(model), prefix, fn _ -> :ok end)

    frame = %{
      "type" => "request",
      "id" => "1",
      "method" => "POST",
      "path" => "/v1/messages",
      "body" => %{"messages" => []}
    }

    Application.put_env(:eab, :http_request, fn opts ->
      if String.ends_with?(opts[:url], "count_tokens") do
        :counters.put(counter, 1, 10)
        {:ok, %{status: 200, body: %{"input_tokens" => 42}}}
      else
        :counters.put(counter, 1, 50)
        raise "synthetic failure"
      end
    end)

    {reply, state} = PiGateway.request(frame, state)
    assert reply["status"] == 502
    assert Store.read("#{prefix}/agent-progress.json")["measurement"]["attempt_ms"] == 50
    :counters.put(counter, 1, 100)

    assert_raise RuntimeError, "synthetic failure", fn ->
      Pi.finish(%{"state" => state, "returncode" => 1})
    end

    run_id = prefix |> String.split("/") |> Enum.at(1)
    result = Agent.error("case", run_id, state.error, "")
    assert result["status"] == "error"
    assert result["measurement"]["attempt_ms"] == 100
  end
end
