defmodule Eab.MemoryMonitor do
  @moduledoc "Run-scoped, process-attributed memory samples streamed from the model host."
  use GenServer, restart: :temporary
  alias Eab.{ModelIdentity, Store}
  @counters ~w(vram_bytes service_ram_bytes process_rss_bytes combined_bytes)

  def label(memory) do
    peaks = memory["peaks"] || %{}

    "#{gb(peaks["vram_bytes"])} VRAM · #{gb(peaks["service_ram_bytes"])} RAM · " <>
      "#{gb(peaks["combined_bytes"])} simultaneous total (#{memory["status"]}, #{memory["sample_count"]} samples)"
  end

  defp gb(nil), do: "—"
  defp gb(bytes), do: "#{Float.round(bytes / 1_000_000_000, 1)} GB"

  def start(run) do
    case configuration(run["model"]) do
      nil ->
        if run["memory"],
          do: {:error, "Restore memory collector configuration before resuming this run"},
          else: {:ok, nil, nil}

      config ->
        {:ok, pid} =
          DynamicSupervisor.start_child(Eab.MemoryMonitors, {__MODULE__, {self(), run, config}})

        case GenServer.call(pid, :ready, 20_000) do
          {:ok, summary} -> {:ok, pid, summary}
          {:error, message} -> {:error, message}
        end
    end
  catch
    :exit, _ -> {:error, "Memory collector stopped before its first sample"}
  end

  def finish(nil, _id, _reason), do: nil

  def finish(pid, id, reason) do
    GenServer.call(pid, {:finish, reason}, 6_000)
  catch
    :exit, _ -> recover(id)
  end

  def recover(id) do
    case Store.read("runs/#{id}/memory.json") do
      nil ->
        nil

      summary ->
        sessions =
          Enum.map(summary["sessions"], fn session ->
            if session["status"] == "sampling",
              do:
                Map.merge(session, %{
                  "status" => "partial",
                  "reason" => "Collector interrupted",
                  "finished_at" => now()
                }),
              else: session
          end)

        summary = summarize(sessions)
        Store.write("runs/#{id}/memory.json", summary)
        summary
    end
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def configuration(endpoint) do
    case configuration_status(endpoint) do
      {:configured, config} -> config
      _ -> nil
    end
  end

  def configuration_label(endpoint) do
    case configuration_status(endpoint) do
      {:configured, _} ->
        "RAM/VRAM collection is configured. The collector must connect before the run can start."

      :disabled ->
        "RAM/VRAM will not be recorded: set EAB_MEMORY_SSH_TARGET and EAB_MEMORY_HOSTS."

      {:unlisted_host, host} ->
        "RAM/VRAM will not be recorded: add #{host} to EAB_MEMORY_HOSTS."

      :unsupported ->
        "RAM/VRAM collection is unavailable for this model source."
    end
  end

  defp configuration_status(endpoint) do
    config = Application.get_env(:eab, :memory_monitor)
    host = URI.parse(endpoint["url"] || "").host

    cond do
      endpoint["backend"] not in ["strata", "llama_cpp"] -> :unsupported
      is_nil(config) -> :disabled
      host not in config[:hosts] -> {:unlisted_host, host}
      true -> {:configured, config}
    end
  end

  # With no key the connection relies on the host's own SSH service, such as Tailscale
  # SSH. A key is for a plain sshd, such as a rig on a direct cable.
  @doc false
  def ssh_args(config) do
    [
      "-F",
      "/dev/null",
      "-T",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=5",
      "-o",
      "ServerAliveInterval=5",
      "-o",
      "ServerAliveCountMax=2",
      "-o",
      "IdentityAgent=none",
      "-o",
      "IdentityFile=#{config[:ssh_key] || "none"}",
      "-o",
      "IdentitiesOnly=yes",
      "-o",
      "StrictHostKeyChecking=yes",
      "-o",
      "UserKnownHostsFile=#{config[:known_hosts]}",
      config[:target],
      "#{quote_shell(config[:collector])} eval 'Eab.MemoryCollector.CLI.main()'"
    ]
  end

  @impl true
  def init({owner, run, config}) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(owner)
    previous = recover(run["id"])
    sessions = if previous, do: previous["sessions"], else: []

    session = %{
      "id" => Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      "status" => "sampling",
      "started_at" => now(),
      "finished_at" => nil,
      "identity" => nil,
      "interval_ms" => 1_000,
      "sample_count" => 0,
      "gap_count" => 0,
      "max_gap_ms" => 0,
      "peaks" => %{},
      "gpus" => [],
      "reason" =>
        if(run["resume_count"] && sessions == [], do: "Earlier run segment was not sampled")
    }

    executable =
      config[:executable] || System.find_executable("ssh") || raise "SSH client is not installed"

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: config[:args] || ssh_args(config)
      ])

    request = %{
      "port" => URI.parse(run["model"]["url"]).port,
      "artifact" => ModelIdentity.details(run["model"])["artifact"],
      "context_tokens" => run["model"]["context"],
      "backend" => run["model"]["backend"],
      "key_file" => config[:key_file]
    }

    Port.command(port, Jason.encode!(request) <> "\n")
    path = "runs/#{run["id"]}/memory-samples.jsonl"
    unless File.exists?(Store.path(path)), do: Store.write_text(path, "")
    Process.send_after(self(), :startup_timeout, 15_000)
    Process.send_after(self(), :watchdog, 5_000)

    state = %{
      owner: owner,
      owner_ref: ref,
      id: run["id"],
      port: port,
      buffer: "",
      sessions: sessions,
      session: session,
      ready: nil,
      stopping: nil,
      sampled: false,
      last_sample: nil,
      last_received: System.monotonic_time(:millisecond),
      last_broadcast: nil
    }

    {:ok, save(state)}
  end

  @impl true
  def handle_call(:ready, from, state) do
    if state.sampled,
      do: {:reply, {:ok, summary(state)}, state},
      else: {:noreply, %{state | ready: from}}
  end

  def handle_call({:finish, reason}, from, state) do
    Port.command(state.port, "stop\n")
    Process.send_after(self(), :stop_timeout, 4_000)
    {:noreply, %{state | stopping: {from, reason}}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    parts = String.split(state.buffer <> data, "\n")
    buffer = List.last(parts)

    if byte_size(buffer) > 65_536 do
      end_session(state, "partial", "Invalid collector output")
    else
      state = %{state | buffer: buffer}

      Enum.reduce_while(Enum.drop(parts, -1), {:noreply, state}, fn line, {:noreply, current} ->
        result =
          case Jason.decode(line) do
            {:ok, event} when is_map(event) -> event(event, current)
            _ -> end_session(current, "partial", invalid_output(line))
          end

        if elem(result, 0) == :stop, do: {:halt, result}, else: {:cont, result}
      end)
    end
  end

  def handle_info({port, {:exit_status, _}}, %{port: port} = state),
    do: end_session(state, "partial", "SSH collector disconnected")

  def handle_info({:EXIT, port, _}, %{port: port} = state),
    do: end_session(state, "partial", "SSH collector closed")

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: end_session(state, "partial", "Benchmark coordinator stopped")

  def handle_info(:startup_timeout, %{sampled: false} = state),
    do: end_session(state, "partial", "No initial memory sample received")

  def handle_info(:startup_timeout, state), do: {:noreply, state}

  def handle_info(:stop_timeout, state),
    do: end_session(state, "partial", "Final sample was not received")

  def handle_info(:watchdog, state) do
    if System.monotonic_time(:millisecond) - state.last_received > 10_000 do
      end_session(state, "partial", "Memory sample stream stalled")
    else
      Process.send_after(self(), :watchdog, 5_000)
      {:noreply, state}
    end
  end

  defp event(%{"type" => "ready", "identity" => identity}, state) do
    {:noreply, %{state | session: Map.put(state.session, "identity", identity)}}
  end

  defp event(%{"type" => "sample"} = sample, state) do
    valid =
      state.session["identity"] &&
        Enum.all?(@counters, &(is_integer(sample[&1]) and sample[&1] >= 0)) &&
        sample["combined_bytes"] == sample["vram_bytes"] + sample["service_ram_bytes"] &&
        is_integer(sample["monotonic_ms"]) && is_list(sample["gpus"]) && sample["gpus"] != []

    if valid do
      raw = Map.put(sample, "session_id", state.session["id"])

      File.write!(
        Store.path("runs/#{state.id}/memory-samples.jsonl"),
        Jason.encode!(raw) <> "\n",
        [:append]
      )

      gap = if state.last_sample, do: sample["monotonic_ms"] - state.last_sample, else: 0

      session =
        state.session
        |> Map.update!("sample_count", &(&1 + 1))
        |> Map.update!("gap_count", &(&1 + if(gap > 2_500, do: 1, else: 0)))
        |> Map.update!("max_gap_ms", &max(&1, gap))
        |> Map.put("last_sample_at", sample["at"])
        |> Map.put("peaks", maxima(state.session["peaks"], Map.take(sample, @counters)))
        |> Map.put("gpus", gpu_maxima(state.session["gpus"], sample["gpus"]))

      state =
        %{
          state
          | session: session,
            sampled: true,
            last_sample: sample["monotonic_ms"],
            last_received: System.monotonic_time(:millisecond)
        }
        |> save()

      if state.ready, do: GenServer.reply(state.ready, {:ok, summary(state)})
      state = %{state | ready: nil}
      received = state.last_received

      state =
        if is_nil(state.last_broadcast) or received - state.last_broadcast >= 5_000 do
          send(state.owner, {:memory_updated, state.id, summary(state)})
          %{state | last_broadcast: received}
        else
          state
        end

      {:noreply, state}
    else
      end_session(state, "partial", "Invalid memory sample")
    end
  end

  defp event(%{"type" => "stopped"}, %{stopping: {_, reason}} = state),
    do: end_session(state, "complete", reason)

  defp event(%{"type" => "error", "message" => message}, state),
    do: end_session(state, "partial", message)

  defp event(_, state), do: end_session(state, "partial", "Unexpected collector event")

  defp end_session(state, status, reason) do
    status =
      if state.session["gap_count"] > 0 or state.session["reason"], do: "partial", else: status

    session =
      Map.merge(state.session, %{
        "status" => status,
        "finished_at" => now(),
        "reason" =>
          state.session["reason"] ||
            if(state.session["gap_count"] > 0, do: "Sampling gap detected", else: reason)
      })

    state = save(%{state | session: session})
    result = summary(state)
    if state.ready, do: GenServer.reply(state.ready, {:error, reason})
    if state.stopping, do: GenServer.reply(elem(state.stopping, 0), result)
    send(state.owner, {:memory_updated, state.id, result})
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_, state) do
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  defp save(state) do
    Store.write("runs/#{state.id}/memory.json", summary(state))
    state
  end

  defp summary(state), do: summarize(state.sessions ++ [state.session])

  defp summarize(sessions) do
    status =
      cond do
        Enum.any?(sessions, &(&1["status"] == "sampling")) -> "sampling"
        Enum.all?(sessions, &(&1["status"] == "complete")) -> "complete"
        true -> "partial"
      end

    %{
      "kind" => "run_samples",
      "status" => status,
      "sessions" => sessions,
      "sample_count" => Enum.sum(Enum.map(sessions, & &1["sample_count"])),
      "peaks" => Enum.reduce(sessions, %{}, &maxima(&2, &1["peaks"]))
    }
  end

  defp maxima(left, right), do: Map.merge(left, right, fn _, a, b -> max(a, b) end)

  defp gpu_maxima(left, right) do
    (left ++ right)
    |> Enum.group_by(& &1["uuid"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_, rows} -> Enum.max_by(rows, & &1["used_bytes"]) end)
  end

  # SSH failures (an unknown host key, refused login) arrive here as plain text on
  # the merged stderr; name the first such line so the cause is visible.
  defp invalid_output(line) do
    excerpt =
      line
      |> String.replace_invalid()
      |> String.replace(~r/[^[:print:]]/u, "")
      |> String.trim()
      |> String.slice(0, 200)

    if excerpt == "",
      do: "SSH or collector returned invalid output",
      else: "SSH or collector returned invalid output: #{excerpt}"
  end

  defp quote_shell(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
