defmodule Eab.ClaudeCode.Broker do
  @moduledoc """
  Pairs the one waiting Claude Code attempt with the solver session (ADR 0010: one
  attempt at a time). The attempt worker registers its workspace; the solver's Agent
  call claims it through a hook; workspace tool calls and the finished transcript are
  then forwarded to that worker, which alone touches the container.
  """
  use GenServer
  alias Eab.ClaudeCode

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Called by an attempt worker once its workspace is ready."
  def register(attempt),
    do: GenServer.call(__MODULE__, {:register, Map.put(attempt, :worker, self())})

  def withdraw, do: GenServer.call(__MODULE__, {:withdraw, self()})

  @doc """
  Claims the waiting attempt for a PreToolUse(Agent) hook. Waits up to `wait` ms for a
  workspace while `run_active?` is true. Returns `{:ok, attempt}`, `{:deny, reason}` or
  `:waiting` when nothing became ready in time.
  """
  def claim(event, kit, run_active?, wait \\ 300_000),
    do: GenServer.call(__MODULE__, {:claim, event, kit, run_active?, wait}, wait + 10_000)

  @doc "Runs one workspace tool call in the claimed attempt's worker."
  def call_tool(name, arguments) do
    case GenServer.call(__MODULE__, :active_worker) do
      nil ->
        {:error,
         "No benchmark attempt is active. These tools work only for a solver started by /solve-run."}

      worker ->
        ref = Process.monitor(worker)
        send(worker, {:eab_tool, self(), ref, name, arguments})

        receive do
          {^ref, result} ->
            Process.demonitor(ref, [:flush])
            {:ok, result}

          {:DOWN, ^ref, :process, _, _} ->
            {:error, "The benchmark attempt stopped before this tool call finished."}
        end
    end
  end

  @doc "Hands a finished solver's transcript to its worker (SubagentStop hook)."
  def finish(event, transcript, error),
    do: GenServer.call(__MODULE__, {:finish, event, transcript, error})

  @doc "After a subscription usage-limit stop, refuse new attempts until released."
  def pause(reason), do: GenServer.call(__MODULE__, {:pause, reason})
  def release_pause, do: GenServer.call(__MODULE__, :release_pause)
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_),
    do: {:ok, %{waiting: nil, active: nil, pollers: [], pause: nil, kit: nil}}

  @impl true
  def handle_call({:register, attempt}, _from, state) do
    if state.waiting || state.active do
      {:reply, {:error, "Another Claude Code attempt is already waiting or running"}, state}
    else
      attempt = Map.put(attempt, :monitor, Process.monitor(attempt.worker))
      {:reply, :ok, wake(%{state | waiting: attempt})}
    end
  end

  def handle_call({:withdraw, worker}, _from, state), do: {:reply, :ok, drop(state, worker)}

  def handle_call({:claim, event, kit, run_active?, wait}, from, state) do
    problems = ClaudeCode.kit_problems(kit)
    state = %{state | kit: %{"problems" => problems}}

    cond do
      problems != [] ->
        {:reply,
         {:deny,
          "The solver folder does not match this controller's Claude Code kit (#{Enum.join(problems, "; ")}). " <>
            "Tell the user to rerun scripts/install-claude-code-kit.sh, then stop."}, state}

      is_binary(event["agent_id"]) ->
        {:reply, {:deny, "Solver subagents cannot start other agents."}, state}

      state.pause ->
        {:reply, {:deny, state.pause}, state}

      state.active ->
        {:reply,
         {:deny,
          "A solver is already working on #{state.active.case}. Wait for it to finish before calling the Agent tool again."},
         state}

      state.waiting ->
        take(state, event, from)

      run_active? and wait > 0 ->
        timer = Process.send_after(self(), {:poll_timeout, from}, wait)
        {:noreply, %{state | pollers: state.pollers ++ [{from, event, timer}]}}

      true ->
        {:reply, :waiting, state}
    end
  end

  def handle_call(:active_worker, _from, state),
    do: {:reply, state.active && state.active.worker, state}

  def handle_call({:finish, event, transcript, error}, _from, state) do
    agent_type = event["agent_type"]

    case state.active do
      %{agent: ^agent_type, worker: worker} = active ->
        send(worker, {:eab_finished, event["agent_id"], transcript, error})
        Process.demonitor(active.monitor, [:flush])
        {:reply, :ok, %{state | active: nil}}

      _ ->
        {:reply, :ignored, state}
    end
  end

  def handle_call({:pause, reason}, _from, state), do: {:reply, :ok, %{state | pause: reason}}
  def handle_call(:release_pause, _from, state), do: {:reply, :ok, %{state | pause: nil}}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       waiting: state.waiting && state.waiting.case,
       active: state.active && state.active.case,
       pause: state.pause,
       kit: state.kit
     }, state}
  end

  @impl true
  def handle_info({:poll_timeout, from}, state) do
    case Enum.split_with(state.pollers, fn {poller, _, _} -> poller == from end) do
      {[_], rest} ->
        GenServer.reply(from, :waiting)
        {:noreply, %{state | pollers: rest}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _, :process, worker, _}, state), do: {:noreply, drop(state, worker)}

  defp take(state, event, from) do
    attempt = state.waiting

    if get_in(event, ["tool_input", "subagent_type"]) == attempt.agent do
      send(attempt.worker, :eab_claimed)
      GenServer.reply(from, {:ok, attempt})
      {:noreply, %{state | waiting: nil, active: attempt}}
    else
      GenServer.reply(
        from,
        {:deny,
         "This run's solver is subagent_type \"#{attempt.agent}\". Call the Agent tool again with that subagent_type."}
      )

      {:noreply, state}
    end
  end

  # A registered workspace answers the oldest waiting Agent call.
  defp wake(%{pollers: [{from, event, timer} | rest], waiting: waiting} = state)
       when not is_nil(waiting) do
    Process.cancel_timer(timer)
    {:noreply, state} = take(%{state | pollers: rest}, event, from)
    wake(state)
  end

  defp wake(state), do: state

  defp drop(state, worker) do
    state =
      if state.waiting && state.waiting.worker == worker do
        Process.demonitor(state.waiting.monitor, [:flush])
        %{state | waiting: nil}
      else
        state
      end

    if state.active && state.active.worker == worker do
      Process.demonitor(state.active.monitor, [:flush])
      %{state | active: nil}
    else
      state
    end
  end
end
