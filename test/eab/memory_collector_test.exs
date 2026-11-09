defmodule Eab.MemoryCollectorTest do
  use ExUnit.Case, async: true
  alias Eab.MemoryCollector, as: Collector

  setup do
    root =
      Path.join(System.tmp_dir!(), "eab-memory-counters-#{System.unique_integer([:positive])}")

    proc = Path.join(root, "proc")
    group = Path.join(root, "groups/model.service")
    File.mkdir_p!(group)

    for pid <- [10, 11] do
      File.mkdir_p!(Path.join(proc, to_string(pid)))

      File.write!(
        Path.join([proc, to_string(pid), "stat"]),
        "#{pid} (model process) " <> Enum.join(List.duplicate("0", 19) ++ ["1234"], " ")
      )

      File.write!(Path.join([proc, to_string(pid), "cgroup"]), "0::/model.service\n")
      File.write!(Path.join([proc, to_string(pid), "status"]), "VmRSS: 20 kB\nVmHWM: 80 kB\n")
    end

    File.write!(Path.join(proc, "cpuinfo"), "model name: Fixture CPU\n")
    File.write!(Path.join(proc, "meminfo"), "MemTotal: 1000 kB\nMemAvailable: 600 kB\n")
    File.write!(Path.join(group, "cgroup.procs"), "10\n11\n")
    File.write!(Path.join(group, "memory.current"), "50000\n")
    File.write!(Path.join(group, "memory.peak"), "90000000\n")
    File.write!(Path.join(group, "memory.stat"), "anon 30000\nfile 18000\nkernel 2000\n")

    command = fn
      "ss", _ ->
        "LISTEN 0 2048 127.0.0.1:8414 0.0.0.0:* users:((\"server\",pid=10,fd=11))"

      "nvidia-smi", ["--query-gpu=uuid,name,memory.total", _] ->
        "b, 3090, 24576\na, 3090, 24576\n"

      "nvidia-smi", ["--query-compute-apps=gpu_uuid,pid,used_gpu_memory", _] ->
        "b, 11, 100\na, 11, 200\na, 99, 500\n"
    end

    http = fn _, _, route ->
      case route do
        "/health" ->
          %{"service" => "strata", "loaded" => true}

        "/props" ->
          %{
            "model_path" => "/private/model-Q4_K_M.gguf",
            "build_info" => "Strata fixture",
            "default_generation_settings" => %{"n_ctx" => 262_144}
          }

        "/metrics" ->
          %{"engine" => %{"kv" => "int8"}}
      end
    end

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      request: %{
        "port" => 8414,
        "artifact" => "model-Q4_K_M.gguf",
        "context_tokens" => 262_144,
        "backend" => "strata"
      },
      opts: [
        proc_root: proc,
        cgroup_root: Path.join(root, "groups"),
        command: command,
        http: http
      ],
      proc: proc,
      group: group
    }
  end

  test "service samples exclude unrelated GPU processes and lifetime peaks", ctx do
    state = Collector.open(ctx.request, ctx.opts)
    assert Collector.identity(state)["context_tokens"] == 262_144
    {sample, state} = Collector.sample(state)
    assert sample["vram_bytes"] == 300 * 1_048_576
    assert sample["service_ram_bytes"] == 50000
    assert sample["combined_bytes"] == 300 * 1_048_576 + 50000
    assert sample["process_rss_bytes"] == 40 * 1024
    assert sample["ram_file_bytes"] == 18000
    assert Enum.map(sample["gpus"], & &1["uuid"]) == ~w(a b)
    refute Map.has_key?(sample, "service_ram_lifetime_peak_bytes")
    File.write!(Path.join(ctx.group, "memory.current"), "60000")
    assert elem(Collector.sample(state), 0)["service_ram_bytes"] == 60000
  end

  test "identity, context and process restarts fail closed", ctx do
    for {key, value} <- [
          {"artifact", "other.gguf"},
          {"context_tokens", 65536},
          {"backend", "llama_cpp"}
        ] do
      assert_raise Collector.Error, fn ->
        Collector.open(Map.put(ctx.request, key, value), ctx.opts)
      end
    end

    {_, state} = Collector.open(ctx.request, ctx.opts) |> Collector.sample()

    File.write!(
      Path.join([ctx.proc, "11", "stat"]),
      "11 (replacement) " <> Enum.join(List.duplicate("0", 19) ++ ["9999"], " ")
    )

    assert_raise Collector.Error, ~r/process disappeared or changed/, fn ->
      Collector.sample(state)
    end
  end

  test "Maya's Strata build metadata identifies the runtime without a health service field",
       ctx do
    original = ctx.opts[:http]

    http = fn endpoint, key, route ->
      if route == "/health",
        do: %{"status" => "ok", "version" => "maya-fixture"},
        else: original.(endpoint, key, route)
    end

    state = Collector.open(ctx.request, Keyword.put(ctx.opts, :http, http))
    assert Collector.identity(state)["backend"] == "strata"
    assert elem(Collector.sample(state), 0)["vram_bytes"] == 300 * 1_048_576
  end

  test "llama.cpp uses the same service and GPU counters", ctx do
    original = ctx.opts[:http]

    http = fn endpoint, key, route ->
      case route do
        "/health" -> %{"status" => "ok"}
        "/props" -> Map.put(original.(endpoint, key, route), "build_info", "llama.cpp fixture")
      end
    end

    state =
      Collector.open(
        Map.put(ctx.request, "backend", "llama_cpp"),
        Keyword.put(ctx.opts, :http, http)
      )

    assert Collector.identity(state)["backend"] == "llama_cpp"
    sample = elem(Collector.sample(state), 0)
    assert sample["vram_bytes"] == 300 * 1_048_576
    assert sample["service_ram_bytes"] == 50000
  end

  test "records all GGUF shards once, leaving missing files unknown", ctx do
    first = Path.join(ctx.proc, "model-IQ3_S-00001-of-00002.gguf")
    second = Path.join(ctx.proc, "model-IQ3_S-00002-of-00002.gguf")
    File.write!(first, "123")
    File.write!(second, "45678")
    File.write!(Path.join(ctx.proc, "unrelated.gguf"), "ignored")
    original = ctx.opts[:http]

    http = fn endpoint, key, route ->
      props = original.(endpoint, key, route)
      if route == "/props", do: Map.put(props, "model_path", first), else: props
    end

    state =
      Collector.open(
        Map.put(ctx.request, "artifact", Path.basename(first)),
        Keyword.put(ctx.opts, :http, http)
      )

    weights = Collector.identity(state)["weight_files"]
    assert weights["size_bytes"] == 8
    assert Enum.map(weights["files"], & &1["name"]) == Enum.map([first, second], &Path.basename/1)
    refute JSON.encode!(weights) =~ ctx.proc
    File.rm!(second)
    assert Collector.identity(state)["weight_files"] == nil
    assert Collector.identity(Collector.open(ctx.request, ctx.opts))["weight_files"] == nil
  end

  test "follows a Strata pack folder to its model's GGUF shards, not its drafter", ctx do
    weights = Path.join(ctx.proc, "weights")
    pack = Path.join(weights, "pack")
    File.mkdir_p!(pack)
    first = "Model-UD-IQ1_M-00001-of-00002.gguf"
    second = "Model-UD-IQ1_M-00002-of-00002.gguf"
    drafter = "dspark-Model-Q8_0.gguf"

    for {name, body} <- [{first, "12"}, {second, "345"}, {drafter, "6"}],
        do: File.write!(Path.join(weights, name), body)

    listing = fn names ->
      lines = names |> Enum.with_index() |> Enum.map(fn {name, i} -> "file #{i} #{name}\n" end)
      File.write!(Path.join(pack, "tensors.txt"), [lines, "t head.weight Q6_K 1 224 5 1 1\n"])
    end

    File.write!(Path.join(pack, "ds4.txt"), "format gguf\nmodel_dir #{weights}\n")
    listing.([first, second, drafter])
    original = ctx.opts[:http]

    http = fn endpoint, key, route ->
      props = original.(endpoint, key, route)
      if route == "/props", do: Map.put(props, "model_path", pack), else: props
    end

    state =
      Collector.open(Map.put(ctx.request, "artifact", "pack"), Keyword.put(ctx.opts, :http, http))

    weights_files = Collector.identity(state)["weight_files"]
    assert weights_files["size_bytes"] == 5
    assert Enum.map(weights_files["files"], & &1["name"]) == [first, second]
    refute JSON.encode!(weights_files) =~ ctx.proc

    # A lone listed file stands for itself; anything ambiguous or unsafe stays unknown.
    listing.([drafter])
    assert Collector.identity(state)["weight_files"]["size_bytes"] == 1

    for names <- [
          [first, drafter, "other-Q4_K-00001-of-00002.gguf"],
          [drafter, "b.gguf"],
          ["../x.gguf"]
        ] do
      listing.(names)
      assert Collector.identity(state)["weight_files"] == nil
    end

    File.rm!(Path.join(pack, "tensors.txt"))
    assert Collector.identity(state)["weight_files"] == nil
  end

  test "GPU allocations aggregate service processes by physical UUID and reject unavailable counters" do
    cards = [["b", "3090", "24576"], ["a", "3090", "24576"]]
    apps = [["b", "10", "100"], ["a", "10", "200"], ["a", "11", "30"], ["a", "99", "500"]]
    result = Collector.gpu_usage(MapSet.new([10, 11]), cards, apps)

    assert Enum.map(result, &{&1["uuid"], &1["used_bytes"]}) == [
             {"a", 230 * 1_048_576},
             {"b", 100 * 1_048_576}
           ]

    assert_raise Collector.Error, fn ->
      Collector.gpu_usage(MapSet.new([10]), cards, [["a", "10", "[N/A]"]])
    end
  end

  test "listener ignores Tailscale forwarder and rejects ambiguous listeners" do
    rows =
      "LISTEN 0 2048 127.0.0.1:8414 0.0.0.0:* users:((\"server\",pid=10,fd=11))\nLISTEN 0 4096 100.70.151.84:8414 0.0.0.0:* users:((\"tailscaled\",pid=1881,fd=27))"

    assert Collector.listener(rows, 8414) == 10

    assert_raise Collector.Error, fn ->
      Collector.listener(
        rows <> "\nLISTEN 0 2048 0.0.0.0:8414 0.0.0.0:* users:((\"server\",pid=11,fd=11))",
        8414
      )
    end
  end

  test "standalone snapshot stays distinct from run samples and omits private identifiers", ctx do
    snapshot = Collector.snapshot(Map.put(ctx.request, "pid", 11), ctx.opts)
    assert snapshot["kind"] == "loaded_snapshot"
    assert snapshot["ram_lifetime_peak_bytes"] == 80 * 1024
    assert snapshot["service_ram_lifetime_peak_bytes"] == 90_000_000
    assert snapshot["model_artifact"] == "model-Q4_K_M.gguf"
    refute JSON.encode!(snapshot) =~ "uuid"
    refute JSON.encode!(snapshot) =~ "/private/"
    assert length(snapshot["gpus"]) == 2
  end
end
