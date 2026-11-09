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

  test "SSH uses a configured key and otherwise offers none" do
    config = [target: "root@10.77.0.2", collector: "/srv/collector", known_hosts: "/data/hosts"]
    assert "IdentityFile=none" in MemoryMonitor.ssh_args(config)

    args = MemoryMonitor.ssh_args([ssh_key: "/data/memory/id_ed25519"] ++ config)
    assert "IdentityFile=/data/memory/id_ed25519" in args
    assert "IdentitiesOnly=yes" in args
    assert "IdentityAgent=none" in args
    assert "StrictHostKeyChecking=yes" in args
    assert "UserKnownHostsFile=/data/hosts" in args
    assert "root@10.77.0.2" in args
  end

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

  test "the model server's API key reaches the collector over SSH" do
    configure("needs_key")
    assert {:error, "No model API key"} = MemoryMonitor.start(run("keyless"))
    assert {:ok, pid, _} = MemoryMonitor.start(run("keyed"), "model-key")
    assert MemoryMonitor.finish(pid, "keyed", "completed")["status"] == "complete"
  end

  test "without a target or host list, root on the endpoint's host once its key is trusted" do
    root = Application.get_env(:eab, :data_dir)
    known = Path.join(root, "memory/known_hosts")
    blob = Base.encode64(:crypto.strong_rand_bytes(51))
    ssh = Path.join(root, "fake-ssh")
    File.mkdir_p!(root)

    # Records the host key ssh would accept into the scratch known_hosts, then fails to log in.
    File.write!(ssh, """
    #!/bin/sh
    for a in "$@"; do case "$a" in UserKnownHostsFile=*) f="${a#UserKnownHostsFile=}";; esac; done
    echo "rig.example ssh-ed25519 #{blob}" > "$f"
    exit 255
    """)

    File.chmod!(ssh, 0o755)

    Application.put_env(:eab, :memory_monitor,
      known_hosts: known,
      collector: "/srv/collector",
      executable: ssh
    )

    rig = %{"url" => "http://rig.example:8460", "backend" => "strata"}
    assert MemoryMonitor.configuration(rig) == nil
    assert MemoryMonitor.untrusted_host(rig) == "rig.example"
    assert MemoryMonitor.configuration_label(rig) =~ "rig.example's SSH host key"

    key = MemoryMonitor.host_key(rig)
    digest = :crypto.hash(:sha256, Base.decode64!(blob))
    assert key.fingerprint == "SHA256:" <> Base.encode64(digest, padding: false)
    refute File.exists?(known)

    assert :ok = MemoryMonitor.trust(rig, key)
    assert MemoryMonitor.configuration(rig)[:target] == "root@rig.example"
    assert MemoryMonitor.untrusted_host(rig) == nil
    assert File.stat!(known).mode |> Bitwise.band(0o777) == 0o600

    # A key read from one host cannot be trusted for another.
    other = %{rig | "url" => "http://other.example:8460"}
    assert MemoryMonitor.untrusted_host(other) == "other.example"
    assert_raise RuntimeError, fn -> MemoryMonitor.trust(other, key) end

    # Hashed entries, as ssh-keyscan -H writes them, count as trusted too.
    salt = :crypto.strong_rand_bytes(20)
    mac = :crypto.mac(:hmac, :sha, salt, "other.example")

    File.write!(known, "|1|#{Base.encode64(salt)}|#{Base.encode64(mac)} ssh-ed25519 #{blob}\n", [
      :append
    ])

    assert MemoryMonitor.configuration(other)[:target] == "root@other.example"

    # A host list still limits which endpoints are sampled; EAB_MEMORY=off configures nothing.
    Application.put_env(:eab, :memory_monitor, known_hosts: known, hosts: ["rig.example"])
    assert MemoryMonitor.configuration_label(other) =~ "add other.example"
    Application.delete_env(:eab, :memory_monitor)
    assert MemoryMonitor.configuration_label(rig) =~ "EAB_MEMORY is off"
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
