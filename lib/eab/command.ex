defmodule Eab.Command do
  @moduledoc "Bounded subprocess output and watchdogs. Watchdogs are never performance evidence."
  alias Eab.Activity

  def with_scope(scope, fun) do
    previous = Process.put(:eab_command_scope, scope)

    try do
      fun.()
    after
      Process.put(:eab_command_scope, previous)
    end
  end

  def run(executable, args, opts \\ []) do
    owner = self()
    ref = make_ref()
    activity = Activity.context()
    scope = Process.get(:eab_command_scope) || owner

    {pid, monitor} =
      spawn_monitor(fn ->
        with_scope(scope, fn ->
          Activity.inherit(activity, fn -> execute(owner, ref, executable, args, opts) end)
        end)
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        raise "Command failed: #{inspect(reason)}"
    end
  end

  def run!(exe, args, opts \\ []) do
    result = run(exe, args, opts)
    if result["returncode"] != 0, do: raise("#{exe} failed: #{result["output"]}")
    result["output"]
  end

  @doc "Exchange JSON lines with a subprocess, keeping cancellation active during callbacks."
  def exchange(exe, args, state, handler, opts \\ []) do
    run(exe, args, Keyword.put(opts, :exchange, {state, handler}))
  end

  def quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp execute(owner, ref, executable, args, opts) do
    Registry.register(Eab.Commands, owner, nil)
    Registry.register(Eab.Commands, {:scope, Process.get(:eab_command_scope)}, nil)
    monitor = Process.monitor(owner)
    unless Process.alive?(owner), do: exit(:owner_stopped)
    timeout = Keyword.get(opts, :timeout, 900)
    limit = Keyword.get(opts, :limit, 20_000)

    setsid =
      System.find_executable("setsid") || raise "setsid is required in the controller image"

    exe = System.find_executable(executable) || raise "Missing executable #{executable}"

    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :use_stdio,
      args: ["--wait", exe | args]
    ]

    port_opts = if opts[:cd], do: port_opts ++ [cd: opts[:cd]], else: port_opts

    Activity.note(
      "$ " <>
        Enum.map_join([executable | args], " ", &__MODULE__.quote/1) <>
        if(opts[:cd], do: "\nWorking directory: #{opts[:cd]}", else: "")
    )

    port = Port.open({:spawn_executable, setsid}, port_opts)
    if opts[:input] && opts[:input] != "", do: Port.command(port, opts[:input])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        # A short-lived command may already have queued its output and exit status.
        nil -> nil
      end

    timer =
      case timeout do
        :infinity -> nil
        seconds -> Process.send_after(self(), :watchdog, seconds * 1000)
      end

    try do
      result =
        case opts[:exchange] do
          {state, handler} -> exchange_collect(port, monitor, os_pid, "", state, handler)
          nil -> collect(port, monitor, os_pid, limit, !opts[:quiet], "", "", 0)
        end

      Activity.note("Process exited with code #{result["returncode"]}")
      send(owner, {ref, result})
    after
      Activity.flush({:command, self()})
      if timer, do: Process.cancel_timer(timer)

      if Port.info(port) do
        kill(os_pid)

        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end
      end
    end
  end

  defp exchange_collect(port, monitor, os_pid, buffer, state, handler) do
    receive do
      {^port, {:data, data}} ->
        chunks = :binary.split(buffer <> data, "\n", [:global])
        {lines, [buffer]} = Enum.split(chunks, -1)
        if byte_size(buffer) > 16_777_216, do: raise("Subprocess JSON line exceeds limit")

        state =
          Enum.reduce(lines, state, fn line, acc ->
            if byte_size(line) > 16_777_216, do: raise("Subprocess JSON line exceeds limit")

            frame =
              case Jason.decode(line) do
                {:ok, frame} when is_map(frame) -> frame
                _ -> raise("Invalid subprocess protocol: #{String.slice(line, 0, 1000)}")
              end

            {reply, acc} = callback(fn -> handler.(frame, acc) end, monitor, os_pid)
            if reply, do: Port.command(port, Jason.encode!(reply) <> "\n")
            acc
          end)

        exchange_collect(port, monitor, os_pid, buffer, state, handler)

      {^port, {:exit_status, code}} ->
        if buffer != "", do: raise("Incomplete subprocess JSON record")
        %{"returncode" => code, "state" => state}

      {:DOWN, ^monitor, :process, _, _} ->
        kill(os_pid)
        exit(:owner_stopped)

      :watchdog ->
        kill(os_pid)
        raise "Command watchdog expired"
    end
  end

  defp callback(fun, owner_monitor, os_pid) do
    parent = self()
    ref = make_ref()
    activity = Activity.context()
    scope = Process.get(:eab_command_scope)

    {pid, monitor} =
      spawn_monitor(fn ->
        with_scope(scope, fn ->
          Activity.inherit(activity, fn -> send(parent, {ref, fun.()}) end)
        end)
      end)

    try do
      receive do
        {^ref, result} ->
          result

        {:DOWN, ^monitor, :process, ^pid, reason} ->
          raise "Subprocess callback failed: #{inspect(reason)}"

        {:DOWN, ^owner_monitor, :process, _, _} ->
          kill(os_pid)
          exit(:owner_stopped)

        :watchdog ->
          kill(os_pid)
          raise "Command watchdog expired"
      end
    after
      Process.exit(pid, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  def await_owner(owner) do
    for {pid, _} <- Registry.lookup(Eab.Commands, owner) do
      monitor = Process.monitor(pid)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _} -> :ok
      after
        10_000 ->
          Process.demonitor(monitor, [:flush])
          raise "Subprocess cleanup watchdog expired"
      end
    end
  end

  def await_scope(scope), do: await_owner({:scope, scope})

  defp collect(port, monitor, os_pid, limit, echo, head, tail, size) do
    receive do
      {^port, {:data, data}} ->
        if echo, do: Activity.output({:command, self()}, data)
        needed = max(div(limit, 2) - byte_size(head), 0)
        take = min(needed, byte_size(data))
        <<first::binary-size(^take), rest::binary>> = data
        tail = tail <> rest

        tail =
          binary_part(
            tail,
            max(byte_size(tail) - div(limit, 2), 0),
            min(byte_size(tail), div(limit, 2))
          )

        collect(port, monitor, os_pid, limit, echo, head <> first, tail, size + byte_size(data))

      {^port, {:exit_status, code}} ->
        Activity.flush({:command, self()})
        output = head <> if(size > limit, do: "\n[output elided]\n", else: "") <> tail

        %{
          "returncode" => code,
          "output" => clean_utf8(output),
          "output_truncated" => size > limit
        }

      {:DOWN, ^monitor, :process, _, _} ->
        kill(os_pid)
        exit(:owner_stopped)

      :watchdog ->
        kill(os_pid)
        raise "Command watchdog expired"
    end
  end

  defp kill(nil), do: :ok

  defp kill(pid) do
    pids = descendants(pid) ++ [pid]

    System.cmd("kill", ["-KILL", "--"] ++ Enum.map(pids, &Integer.to_string/1),
      stderr_to_stdout: true
    )
  end

  defp descendants(pid) do
    case File.read("/proc/#{pid}/task/#{pid}/children") do
      {:ok, children} ->
        String.split(children)
        |> Enum.flat_map(fn child ->
          n = String.to_integer(child)
          descendants(n) ++ [n]
        end)

      _ ->
        []
    end
  end

  defp clean_utf8(body), do: for(<<c::utf8 <- body>>, into: "", do: <<c::utf8>>)
end
