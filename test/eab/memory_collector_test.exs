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

  # A GGUF header: magic, version, no tensors, then key/value entries.
  defp gguf(entries) do
    encode = fn
      8, text ->
        <<byte_size(text)::little-64, text::binary>>

      4, number ->
        <<number::little-32>>

      9, list ->
        <<8::little-32, length(list)::little-64>> <>
          Enum.map_join(list, &<<byte_size(&1)::little-64, &1::binary>>)
    end

    <<"GGUF", 3::little-32, 0::little-64, length(entries)::little-64>> <>
      Enum.map_join(entries, fn {key, type, value} ->
        <<byte_size(key)::little-64, key::binary, type::little-32>> <> encode.(type, value)
      end)
  end

  test "names the maker a GGUF header gives, past other keys and arrays, and no one otherwise",
       ctx do
    alias Eab.MemoryCollector.Weights
    dir = Path.join(ctx.proc, "makers")
    File.mkdir_p!(dir)
    first = Path.join(dir, "Model-Q8_0-00001-of-00002.gguf")

    File.write!(
      first,
      gguf([
        {"general.architecture", 8, "qwen4exp"},
        {"general.file_type", 4, 7},
        # Makers often write their name after the tokenizer's arrays, megabytes in.
        {"tokenizer.ggml.tokens", 9, List.duplicate("token", 500_000)},
        {"general.quantized_by", 8, " Unsloth "}
      ])
    )

    File.write!(Path.join(dir, "Model-Q8_0-00002-of-00002.gguf"), "weights")
    assert %{"quantized_by" => "Unsloth", "files" => [_, _]} = Weights.read(first)

    silent = Path.join(dir, "Silent-Q8_0.gguf")
    File.write!(silent, gguf([{"general.name", 8, "Swift 1.5"}]))
    refute Map.has_key?(Weights.read(silent), "quantized_by")

    # A header cut short still counts the file; it only names no one.
    broken = Path.join(dir, "Broken-Q8_0.gguf")
    File.write!(broken, <<"GGUF", 3::little-32, 0::little-64, 5::little-64, 99::little-64>>)
    assert Weights.read(broken)["size_bytes"] > 0
    refute Map.has_key?(Weights.read(broken), "quantized_by")
  end

  test "counts the GGUF files a Strata pack lists, except a drafter-only file", ctx do
    weights = Path.join(ctx.proc, "weights")
    pack = Path.join(weights, "pack")
    File.mkdir_p!(pack)
    # Shards 1-2 of 3 plus an Engram table from another release, as on the rig.
    first = "Model-IQ2_XXS-00001-of-00003.gguf"
    second = "Model-IQ2_XXS-00002-of-00003.gguf"
    engram = "Model-Engram-IQ4_NL.gguf"
    drafter = "dspark-Model-Q8_0.gguf"

    for {name, body} <- [{first, "1"}, {second, "23"}, {engram, "456"}, {drafter, "7890"}],
        do: File.write!(Path.join(weights, name), body)

    # Shard 1 holds metadata only; the drafter file holds only mtp.* tensors.
    listing = fn files, tensors ->
      lines = files |> Enum.with_index() |> Enum.map(fn {name, i} -> "file #{i} #{name}\n" end)
      placed = Enum.map(tensors, fn {name, i} -> "t #{name} Q6_K #{i} 224 5 1 1\n" end)
      File.write!(Path.join(pack, "tensors.txt"), [lines, placed])
    end

    File.write!(Path.join(pack, "ds4.txt"), "format gguf\nmodel_dir #{weights}\n")

    model = [{"head.weight", 1}, {"layers.1.engram.embed.weight", 2}, {"mtp.0.ffn.weight", 3}]
    listing.([first, second, engram, drafter], model)
    original = ctx.opts[:http]

    http = fn endpoint, key, route ->
      props = original.(endpoint, key, route)
      if route == "/props", do: Map.put(props, "model_path", pack), else: props
    end

    state =
      Collector.open(Map.put(ctx.request, "artifact", "pack"), Keyword.put(ctx.opts, :http, http))

    weights_files = Collector.identity(state)["weight_files"]
    assert weights_files["size_bytes"] == 6
    assert Enum.map(weights_files["files"], & &1["name"]) == [first, second, engram]
    refute JSON.encode!(weights_files) =~ ctx.proc

    # A file shared by drafter and model tensors is the model's.
    listing.([first, second, drafter], [{"head.weight", 1}, {"mtp.0.w", 2}, {"norm.weight", 2}])
    assert Collector.identity(state)["weight_files"]["size_bytes"] == 7

    # A missing listed file, an unsafe name or no listing leaves the size unknown.
    for files <- [[first, "absent.gguf"], ["../x.gguf"], []] do
      listing.(files, [])
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
