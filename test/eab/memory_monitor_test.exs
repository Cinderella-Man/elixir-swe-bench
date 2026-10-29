defmodule Eab.MemoryMonitorTest do
  use ExUnit.Case, async: false
  alias Eab.{MemoryMonitor, Store}

  setup do
    keys = [:data_dir, :memory_monitor]
    old = Map.new(keys, &{&1, Application.get_env(:eab, &1)})
    root = Path.join(System.tmp_dir!(), "eab-memory-#{System.unique_integer([:positive])}")
    Application.put_env(:eab, :data_dir, root)

    on_exit(fn ->
      for {key, value} <- old do
        if value == nil,
          do: Application.delete_env(:eab, key),
          else: Application.put_env(:eab, key, value)
      end

      File.rm_rf!(root)
    end)

    configure("normal")
    :ok
  end

  defp configure(mode) do
    Application.put_env(:eab, :memory_monitor,
      hosts: ["fixture"],
      target: "fixture",
      collector: "fixture",
      known_hosts: "fixture",
      executable: "/opt/pi/node",
      args: ["test/support/memory_collector.mjs", mode]
    )
  end

  defp run(id \\ "memory-test"),
    do: %{
      "id" => id,
      "model" => %{
        "url" => "http://fixture:8414",
        "backend" => "strata",
        "context" => 262_144,
        "profile" => %{"model_path" => "/models/fixture-Q4_K_M.gguf"}
      }
    }

  test "saves attributed peaks and simultaneous total, including the final sample and resume sessions" do
    assert {:ok, pid, initial} = MemoryMonitor.start(run())
    assert initial["status"] == "sampling"
    result = MemoryMonitor.finish(pid, "memory-test", "cancelled")
    assert result["status"] == "complete"
    assert result["sample_count"] == 2

    assert result["peaks"] == %{
             "vram_bytes" => 100,
             "service_ram_bytes" => 80,
             "combined_bytes" => 120,
             "process_rss_bytes" => 80
           }

    assert hd(result["sessions"])["gpus"] |> hd() |> Map.fetch!("used_bytes") == 100
    assert Store.read("runs/memory-test/memory.json") == result

    assert {:ok, resumed, _} =
             MemoryMonitor.start(Map.merge(run(), %{"resume_count" => 1, "memory" => result}))

    result = MemoryMonitor.finish(resumed, "memory-test", "completed")
    assert length(result["sessions"]) == 2

    samples =
      File.read!(Store.path("runs/memory-test/memory-samples.jsonl"))
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert length(samples) == 4
    assert Enum.uniq_by(samples, & &1["session_id"]) |> length() == 2
  end

  test "gaps and old unmeasured segments cannot claim complete coverage" do
    configure("gap")
    {:ok, pid, _} = MemoryMonitor.start(run())
    result = MemoryMonitor.finish(pid, "memory-test", "completed")
    assert result["status"] == "partial"
    assert hd(result["sessions"])["gap_count"] == 1
    configure("normal")
    {:ok, pid, _} = MemoryMonitor.start(Map.put(run("old-run"), "resume_count", 1))
    assert MemoryMonitor.finish(pid, "old-run", "completed")["status"] == "partial"
  end

  test "disconnection preserves samples and fails coverage, startup errors block the run" do
    configure("disconnect")
    {:ok, pid, _} = MemoryMonitor.start(run())
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 3000
    result = MemoryMonitor.finish(pid, "memory-test", "completed")
    assert result["status"] == "partial"
    assert result["sample_count"] == 1
    configure("startup_error")
    assert {:error, _} = MemoryMonitor.start(run("bad-model"))
    configure("ssh_error")

    assert {:error, "SSH or collector returned invalid output: Host key verification failed."} =
             MemoryMonitor.start(run("unknown-host"))
  end

  test "collector follows coordinator lifetime and recovery marks unfinished sessions partial" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, pid, _} = MemoryMonitor.start(run())
        send(parent, {:collector, pid})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:collector, pid}, 3000
    ref = Process.monitor(pid)
    send(owner, :exit)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 3000
    result = Store.read("runs/memory-test/memory.json")
    assert result["status"] == "partial"
    interrupted = put_in(result, ["sessions", Access.at(0), "status"], "sampling")
    Store.write("runs/memory-test/memory.json", interrupted)
    assert MemoryMonitor.recover("memory-test")["status"] == "partial"
  end

  test "API endpoints and other hosts are excluded, previously monitored resumes require configuration" do
    assert MemoryMonitor.configuration(%{"url" => "http://other:8414", "backend" => "strata"}) ==
             nil

    assert MemoryMonitor.configuration(%{
             "url" => "http://fixture:8414",
             "backend" => "openai_subscription"
           }) == nil

    Application.delete_env(:eab, :memory_monitor)
    assert {:ok, nil, nil} = MemoryMonitor.start(run())
    assert {:error, _} = MemoryMonitor.start(Map.put(run(), "memory", %{}))
  end
end
