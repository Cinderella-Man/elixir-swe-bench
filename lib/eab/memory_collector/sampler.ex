defmodule Eab.MemoryCollector.Error do
  defexception [:message]
end

defmodule Eab.MemoryCollector do
  @moduledoc "Reads Linux model-service memory counters without inference. Uses only Elixir/OTP."

  def open(request, opts \\ []) do
    port = request["port"]
    ensure!(is_integer(port) and port in 1..65535, "Invalid model endpoint port")

    state = %{
      endpoint: "http://127.0.0.1:#{port}",
      key: request_key(request),
      proc: opts[:proc_root] || "/proc",
      groups: opts[:cgroup_root] || "/sys/fs/cgroup",
      command: opts[:command] || (&command/2),
      http: opts[:http] || (&http/3),
      gpu_processes: nil,
      gpu_ids: nil
    }

    pid = listener(state.command.("ss", ["-H", "-ltnp", "sport = :#{port}"]), port)
    group = group_for(state.proc, pid)
    expected = model(state)

    ensure!(
      expected["model_artifact"] == request["artifact"] and
        expected["context_tokens"] == request["context_tokens"],
      "Loaded model artifact or context differs from the benchmark endpoint"
    )

    ensure!(
      expected["backend"] == request["backend"],
      "Loaded runtime differs from the benchmark endpoint"
    )

    Map.merge(state, %{
      pid: pid,
      started: process_identity(state.proc, pid),
      group: group,
      cgroup: Path.join(state.groups, String.trim_leading(group, "/")),
      expected: expected
    })
  end

  def identity(state) do
    engine =
      if state.expected["backend"] == "strata",
        do: get(state, "/metrics")["engine"] || %{},
        else: %{}

    {:ok, host} = :inet.gethostname()

    Map.merge(state.expected, %{
      "host" => to_string(host),
      "service" => Path.basename(state.group),
      "kv_cache" => engine["kv"],
      "weight_files" => Eab.MemoryCollector.Weights.read(get(state, "/props")["model_path"]),
      "cpu" => cpu(state.proc)
    })
  end

  def sample(state) do
    ensure!(
      process_identity(state.proc, state.pid) == state.started and
        group_for(state.proc, state.pid) == state.group and model(state) == state.expected,
      "Model server identity changed during collection"
    )

    pids =
      Path.wildcard(Path.join(state.cgroup, "**/cgroup.procs"))
      |> Enum.flat_map(&(File.read!(&1) |> String.split()))
      |> Enum.map(&String.to_integer/1)
      |> MapSet.new()

    ensure!(MapSet.member?(pids, state.pid), "Model server left its service")
    processes = gpu_rows(state, "--query-compute-apps=gpu_uuid,pid,used_gpu_memory")

    engines =
      processes
      |> Enum.map(fn [_, pid, _] -> String.to_integer(pid) end)
      |> Enum.filter(&MapSet.member?(pids, &1))
      |> Map.new(&{&1, process_identity(state.proc, &1)})

    ensure!(
      map_size(engines) > 0 and (is_nil(state.gpu_processes) or engines == state.gpu_processes),
      "Inference GPU process disappeared or changed"
    )

    gpus = gpu_usage(pids, gpu_rows(state, "--query-gpu=uuid,name,memory.total"), processes)
    ids = Enum.map(gpus, & &1["uuid"])
    ensure!(is_nil(state.gpu_ids) or ids == state.gpu_ids, "Model GPU placement changed")

    rss =
      Enum.reduce(pids, 0, fn pid, total ->
        case File.read(Path.join([state.proc, to_string(pid), "status"])) do
          {:ok, body} ->
            total + kib(pairs(body, ":"), "VmRSS", 0)

          {:error, :enoent} when pid != state.pid ->
            ensure!(
              not Map.has_key?(engines, pid),
              "Inference process disappeared while sampling"
            )

            total

          {:error, _} ->
            raise "Process memory counter is unavailable"
        end
      end)

    ram = counter(state.cgroup, "memory.current")
    stat = File.read!(Path.join(state.cgroup, "memory.stat")) |> pairs(~r/\s+/)
    host = File.read!(Path.join(state.proc, "meminfo")) |> pairs(":")
    host_total = kib(host, "MemTotal")

    ensure!(
      process_identity(state.proc, state.pid) == state.started and
        Enum.all?(engines, fn {pid, started} -> process_identity(state.proc, pid) == started end),
      "Process restarted while sampling"
    )

    vram = Enum.sum(Enum.map(gpus, & &1["used_bytes"]))

    sample = %{
      "type" => "sample",
      "at" => now(),
      "monotonic_ms" => System.monotonic_time(:millisecond),
      "gpus" => gpus,
      "vram_bytes" => vram,
      "service_ram_bytes" => ram,
      "process_rss_bytes" => rss,
      "ram_anon_bytes" => String.to_integer(stat["anon"] || "0"),
      "ram_file_bytes" => String.to_integer(stat["file"] || "0"),
      "ram_kernel_bytes" => String.to_integer(stat["kernel"] || "0"),
      "combined_bytes" => vram + ram,
      "host_ram_total_bytes" => host_total,
      "host_ram_used_bytes" => host_total - kib(host, "MemAvailable")
    }

    {sample, %{state | gpu_processes: engines, gpu_ids: ids}}
  end

  def snapshot(request, opts \\ []) do
    pid = request["pid"]
    ensure!(is_integer(pid) and pid > 0, "Invalid inference process PID")
    port = request["port"]
    ensure!(is_integer(port) and port in 1..65535, "Invalid model endpoint port")

    state = %{
      proc: opts[:proc_root] || "/proc",
      groups: opts[:cgroup_root] || "/sys/fs/cgroup",
      endpoint: "http://127.0.0.1:#{port}",
      key: request_key(request),
      command: opts[:command] || (&command/2),
      http: opts[:http] || (&http/3)
    }

    started = process_identity(state.proc, pid)
    expected = model(state)

    engine =
      if expected["backend"] == "strata", do: get(state, "/metrics")["engine"] || %{}, else: %{}

    status = File.read!(Path.join([state.proc, to_string(pid), "status"])) |> pairs(":")

    gpus =
      gpu_usage(
        MapSet.new([pid]),
        gpu_rows(state, "--query-gpu=uuid,name,memory.total"),
        gpu_rows(state, "--query-compute-apps=gpu_uuid,pid,used_gpu_memory")
      )

    ensure!(gpus != [], "No NVIDIA GPU allocation found for the selected process")
    group = Path.join(state.groups, String.trim_leading(group_for(state.proc, pid), "/"))
    ensure!(started == process_identity(state.proc, pid), "Process changed while sampling")

    Map.merge(expected, %{
      "kind" => "loaded_snapshot",
      "observed_at" => now(),
      "kv_cache" => engine["kv"],
      "cpu" => cpu(state.proc),
      "gpus" => Enum.map(gpus, &Map.delete(&1, "uuid")),
      "ram_rss_bytes" => kib(status, "VmRSS"),
      "ram_lifetime_peak_bytes" => kib(status, "VmHWM"),
      "service_ram_bytes" => counter(group, "memory.current"),
      "service_ram_lifetime_peak_bytes" => optional_counter(group, "memory.peak")
    })
  end

  def listener(output, port) do
    pids =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn row ->
        fields = String.split(row)

        if Enum.at(fields, 3) in [
             "127.0.0.1:#{port}",
             "0.0.0.0:#{port}",
             "*:#{port}",
             "[::]:#{port}"
           ],
           do:
             Regex.scan(~r/pid=(\d+)/, row, capture: :all_but_first)
             |> List.flatten()
             |> Enum.map(&String.to_integer/1),
           else: []
      end)
      |> Enum.uniq()

    ensure!(length(pids) == 1, "Expected one local model-server listener")
    hd(pids)
  end

  def gpu_usage(pids, devices, processes) do
    cards =
      Map.new(devices, fn [uuid, name, total] -> {uuid, {name, integer!(total) * 1_048_576}} end)

    processes
    |> Enum.reduce(%{}, fn [uuid, pid, used], acc ->
      if MapSet.member?(pids, String.to_integer(pid)),
        do: Map.update(acc, uuid, integer!(used) * 1_048_576, &(&1 + integer!(used) * 1_048_576)),
        else: acc
    end)
    |> Enum.sort()
    |> Enum.map(fn {uuid, used} ->
      {name, capacity} = Map.fetch!(cards, uuid)
      %{"uuid" => uuid, "name" => name, "capacity_bytes" => capacity, "used_bytes" => used}
    end)
  end

  # NVIDIA names and UUIDs contain no CSV delimiters; reject unexpected shapes.
  defp gpu_rows(state, query) do
    state.command.("nvidia-smi", [query, "--format=csv,noheader,nounits"])
    |> String.split("\n", trim: true)
    |> Enum.map(fn row ->
      fields = String.split(row, ",") |> Enum.map(&String.trim/1)
      ensure!(length(fields) == 3, "Unexpected NVIDIA counter format")
      fields
    end)
  end

  defp model(state) do
    health = get(state, "/health")
    props = get(state, "/props")
    ensure!(health["loaded"] != false, "Model is not loaded")

    %{
      "model_artifact" => Path.basename(Map.fetch!(props, "model_path")),
      "context_tokens" => get_in(props, ["default_generation_settings", "n_ctx"]),
      # Maya's wrapper reports its Strata engine in /props but not /health.
      # Keep this detection aligned with Eab.Model.discover/2.
      "backend" =>
        if(
          health["service"] == "strata" or
            String.contains?(String.downcase(to_string(props["build_info"])), "strata"),
          do: "strata",
          else: "llama_cpp"
        ),
      "backend_version" => props["build_info"]
    }
  end

  defp get(state, route), do: state.http.(state.endpoint, state.key, route)
  # The benchmark sends the model server's API key over SSH; older benchmarks name a key file
  # on this host instead. The key only authenticates requests to that server.
  defp request_key(%{"key" => key}) when is_binary(key) and key != "", do: key
  defp request_key(request), do: key(request["key_file"])

  defp key(path) when path in [nil, ""], do: ""
  defp key(path), do: File.read!(path) |> String.trim()

  defp process_identity(root, pid) do
    File.read!(Path.join([root, to_string(pid), "stat"]))
    |> String.split(")")
    |> List.last()
    |> String.split()
    |> Enum.fetch!(19)
  end

  defp group_for(root, pid) do
    group =
      File.read!(Path.join([root, to_string(pid), "cgroup"]))
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "0::"))

    ensure!(is_binary(group), "Model server needs cgroup v2")
    group = String.replace_prefix(group, "0::", "")

    ensure!(
      String.ends_with?(group, [".service", ".scope"]) and not String.contains?(group, ".."),
      "Model server needs a dedicated cgroup v2 service or scope"
    )

    group
  end

  defp cpu(proc),
    do: (File.read!(Path.join(proc, "cpuinfo")) |> pairs(":"))["model name"] || "Unknown"

  defp pairs(body, separator) do
    body
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn row ->
      case String.split(row, separator, parts: 2) do
        [k, v] -> [{String.trim(k), String.trim(v)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp kib(values, key, default \\ nil) do
    if value = values[key],
      do: value |> String.split() |> hd() |> String.to_integer() |> Kernel.*(1024),
      else: default
  end

  defp counter(dir, file),
    do: File.read!(Path.join(dir, file)) |> String.trim() |> String.to_integer()

  defp optional_counter(dir, file),
    do: if(File.regular?(Path.join(dir, file)), do: counter(dir, file))

  defp integer!(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> raise Eab.MemoryCollector.Error, "GPU allocation is unavailable"
    end
  end

  defp http(endpoint, key, route) do
    {:ok, _} = Application.ensure_all_started(:inets)

    headers =
      if key == "", do: [], else: [{~c"authorization", String.to_charlist("Bearer " <> key)}]

    case :httpc.request(
           :get,
           {String.to_charlist(endpoint <> route), headers},
           [timeout: 5_000, connect_timeout: 5_000, autoredirect: false],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} -> JSON.decode!(body)
      _ -> raise "Model properties could not be read"
    end
  end

  defp command(executable, args) do
    port =
      Port.open(
        {:spawn_executable,
         System.find_executable(executable) || raise("Memory counter command is unavailable")},
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: args]
      )

    deadline = System.monotonic_time(:millisecond) + 5_000

    try do
      command_output(port, deadline, "")
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp command_output(port, deadline, output) do
    receive do
      {^port, {:data, data}} ->
        ensure!(
          byte_size(output) + byte_size(data) < 1_048_576,
          "Oversized memory counter output"
        )

        command_output(port, deadline, output <> data)

      {^port, {:exit_status, 0}} ->
        output

      {^port, {:exit_status, _}} ->
        raise "Memory counter command failed"
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        raise "Memory counter command timed out"
    end
  end

  defp ensure!(condition, message),
    do: unless(condition, do: raise(Eab.MemoryCollector.Error, message))

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
