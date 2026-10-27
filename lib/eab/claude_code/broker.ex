defmodule Eab.ClaudeCode.Broker do
  @moduledoc """
  Pairs waiting Claude Code attempts with the solver session's subagents (ADR 0010,
  ADR 0014). Attempt workers register their workspaces. The solver's Agent call claims
  the oldest one through a PreToolUse hook; Claude Code's PostToolUse report of that call
  names the new subagent's `agent_id`, which binds it to the attempt. Workspace tool
  calls carry the calling subagent's `agent_id` (the kit's hook adds it), so they, the
  stop event and the transcript reach only that attempt's worker, which alone touches
  its container. Every hook event is appended to the run's `claude-code-hooks.jsonl`.
  """
  use GenServer
  require Logger
  alias Eab.{ClaudeCode, Store}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Called by an attempt worker once its workspace is ready."
  def register(attempt),
    do: GenServer.call(__MODULE__, {:register, Map.put(attempt, :worker, self())})

  def withdraw, do: GenServer.call(__MODULE__, {:withdraw, self()})

  @doc """
  Claims the oldest waiting attempt for a PreToolUse(Agent) hook. `run` is `nil` when no
  Claude Code run is active, otherwise `%{parallel: n}`. Waits up to `wait` ms for a
  workspace while the run has room for another solver. Returns `{:ok, attempt}`,
  `{:deny, reason}`, `:busy` when every solver slot is working, or `:waiting` when no
  workspace became ready in time.
  """
  def claim(event, kit, run, wait \\ 300_000),
    do: GenServer.call(__MODULE__, {:claim, event, kit, run, wait}, wait + 10_000)

  @doc "PostToolUse(Agent): binds the launched subagent's agent_id to its claimed attempt."
  def bind(event), do: GenServer.call(__MODULE__, {:bind, event})

  @doc "Runs one workspace tool call in the worker bound to `agent_id`."
  def call_tool(agent_id, name, arguments) do
    case worker(agent_id) do
      {:error, message} ->
        {:error, message}

      {:ok, worker} ->
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

  defp worker(agent_id) when is_binary(agent_id) and agent_id != "",
    do: GenServer.call(__MODULE__, {:worker, agent_id}, bind_wait() + 10_000)

  defp worker(_),
    do:
      {:error,
       "This tool call carries no solver identity. These tools work only for a solver started by /solve-run with the current kit."}

  @doc """
  SubagentStop's immediate notice: the solver stopped and its transcript follows. It no
  longer counts as working, so the session's next Agent call may claim a new workspace.
  """
  def stopping(event), do: GenServer.call(__MODULE__, {:stopping, event})

  @doc """
  Solvers the session reports as finished (from Claude Code's subagent records) that this
  broker still counts as working never sent SubagentStop. They are marked stopped and
  returned, so the hook uploads their transcripts.
  """
  def recover(solvers), do: GenServer.call(__MODULE__, {:recover, solvers})

  @doc "Hands a finished solver's transcript to its worker (SubagentStop hook)."
  def finish(event, transcript, error),
    do: GenServer.call(__MODULE__, {:finish, event, transcript, error})

  @doc "After a subscription usage-limit stop, refuse new attempts until released."
  def pause(reason), do: GenServer.call(__MODULE__, {:pause, reason})
  def release_pause, do: GenServer.call(__MODULE__, :release_pause)
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_) do
    {:ok,
     %{
       waiting: [],
       launching: %{},
       active: %{},
       pollers: [],
       binders: [],
       pause: nil,
       kit: nil
     }}
  end

  @impl true
  def handle_call({:register, attempt}, _from, state) do
    if Enum.any?(attempts(state), &(&1.worker == attempt.worker or &1.case == attempt.case)) do
      {:reply, {:error, "This Claude Code attempt is already waiting or running"}, state}
    else
      attempt = Map.put(attempt, :monitor, Process.monitor(attempt.worker))
      log(attempt.run_id, %{"broker" => "registered", "case" => attempt.case})
      {:reply, :ok, wake(%{state | waiting: state.waiting ++ [attempt]})}
    end
  end

  def handle_call({:withdraw, worker}, _from, state), do: {:reply, :ok, drop(state, worker)}

  def handle_call({:claim, event, kit, run, wait}, from, state) do
    problems = ClaudeCode.kit_problems(kit)
    state = %{state | kit: %{"problems" => problems}}

    reply =
      cond do
        problems != [] ->
          {:deny,
           "The solver folder does not match this controller's Claude Code kit (#{Enum.join(problems, "; ")}). " <>
             "Tell the user to rerun scripts/install-claude-code-kit.sh, then stop."}

        is_binary(event["agent_id"]) ->
          {:deny, "Solver subagents cannot start other agents."}

        state.pause ->
          {:deny, state.pause}

        not is_binary(event["tool_use_id"]) ->
          {:deny,
           "This Agent call carries no tool_use_id, so its solver cannot be told apart from others. " <>
             "Tell the user to update Claude Code, then stop."}

        state.waiting != [] ->
          :take

        is_nil(run) ->
          :waiting

        working(state) >= run.parallel ->
          :busy

        wait > 0 ->
          :poll

        true ->
          :waiting
      end

    if run && reply != :take,
      do:
        log(run.id, %{
          "broker" => "agent call",
          "tool_use_id" => event["tool_use_id"],
          "decision" => if(is_tuple(reply), do: elem(reply, 0), else: reply),
          "solvers" => working(state)
        })

    case reply do
      :take ->
        take(state, event, from)

      :poll ->
        timer = Process.send_after(self(), {:poll_timeout, from}, wait)
        {:noreply, %{state | pollers: state.pollers ++ [{from, event, timer}]}}

      reply ->
        {:reply, reply, state}
    end
  end

  def handle_call({:bind, event}, _from, state) do
    tool_use_id = event["tool_use_id"]
    agent_id = get_in(event, ["tool_response", "agentId"])

    case Map.pop(state.launching, tool_use_id) do
      {%{} = attempt, launching} when is_binary(agent_id) and agent_id != "" ->
        Process.cancel_timer(attempt.launch_timer)

        if Map.has_key?(state.active, agent_id) do
          log(attempt.run_id, %{
            "broker" => "duplicate agent_id",
            "case" => attempt.case,
            "agent_id" => agent_id
          })

          {:reply, :ignored, %{state | launching: launching}}
        else
          attempt = attempt |> Map.delete(:launch_timer) |> Map.put(:agent_id, agent_id)
          send(attempt.worker, {:eab_claimed, agent_id})

          log(attempt.run_id, %{
            "broker" => "bound",
            "case" => attempt.case,
            "agent_id" => agent_id,
            "tool_use_id" => tool_use_id
          })

          state = %{
            state
            | launching: launching,
              active: Map.put(state.active, agent_id, attempt)
          }

          {:reply, :ok, answer_binders(state, agent_id)}
        end

      {%{} = attempt, _} ->
        # The launch failed or Claude Code did not report the subagent: offer the
        # workspace again instead of leaving it claimed.
        Process.cancel_timer(attempt.launch_timer)

        log(attempt.run_id, %{
          "broker" => "launch not reported",
          "case" => attempt.case,
          "tool_use_id" => tool_use_id,
          "tool_response" => summary(event["tool_response"])
        })

        {:reply, :requeued, requeue(state, tool_use_id)}

      {nil, _} ->
        {:reply, :ignored, state}
    end
  end

  def handle_call({:worker, agent_id}, from, state) do
    case state.active do
      %{^agent_id => attempt} ->
        {:reply, {:ok, attempt.worker}, state}

      _ when map_size(state.launching) > 0 ->
        timer = Process.send_after(self(), {:bind_timeout, from}, bind_wait())
        {:noreply, %{state | binders: state.binders ++ [{from, agent_id, timer}]}}

      _ ->
        {:reply, unknown(agent_id), state}
    end
  end

  def handle_call({:stopping, event}, _from, state) do
    agent_id = event["agent_id"]

    case state.active do
      %{^agent_id => attempt} ->
        log(attempt.run_id, %{
          "broker" => "stopped",
          "case" => attempt.case,
          "agent_id" => agent_id
        })

        {:reply, :ok, put_in(state.active[agent_id], Map.put(attempt, :stopping, true))}

      _ ->
        {:reply, :ignored, state}
    end
  end

  def handle_call({:recover, solvers}, _from, state) do
    {recovered, state} =
      Enum.reduce(solvers, {[], state}, fn solver, {recovered, state} ->
        agent_id = is_map(solver) && solver["agent_id"]

        case state.active do
          %{^agent_id => %{stopping: true}} ->
            {recovered, state}

          %{^agent_id => attempt} ->
            log(attempt.run_id, %{
              "broker" => "stop not reported; recovered from the session",
              "case" => attempt.case,
              "agent_id" => agent_id
            })

            upload = Map.take(solver, ~w(agent_id agent_type agent_transcript_path))

            {[upload | recovered],
             put_in(state.active[agent_id], Map.put(attempt, :stopping, true))}

          _ ->
            {recovered, state}
        end
      end)

    {:reply, Enum.reverse(recovered), state}
  end

  def handle_call({:finish, event, transcript, error}, _from, state) do
    agent_id = event["agent_id"]

    case Map.pop(state.active, agent_id) do
      {%{worker: worker} = attempt, active} ->
        send(worker, {:eab_finished, event, transcript, error})
        Process.demonitor(attempt.monitor, [:flush])

        log(attempt.run_id, %{
          "broker" => "finished",
          "case" => attempt.case,
          "agent_id" => agent_id,
          "transcript" => is_binary(transcript)
        })

        {:reply, :ok, %{state | active: active}}

      {nil, _} ->
        Logger.warning("Claude Code SubagentStop for an unknown solver #{inspect(agent_id)}")
        {:reply, :ignored, state}
    end
  end

  def handle_call({:pause, reason}, _from, state), do: {:reply, :ok, %{state | pause: reason}}
  def handle_call(:release_pause, _from, state), do: {:reply, :ok, %{state | pause: nil}}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       waiting: Enum.map(state.waiting, & &1.case),
       launching: state.launching |> Map.values() |> Enum.map(& &1.case) |> Enum.sort(),
       active:
         state.active
         |> Map.values()
         |> Enum.map(&%{case: &1.case, agent_id: &1.agent_id})
         |> Enum.sort_by(& &1.case),
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

  def handle_info({:bind_timeout, from}, state) do
    case Enum.split_with(state.binders, fn {binder, _, _} -> binder == from end) do
      {[{_, agent_id, _}], rest} ->
        GenServer.reply(from, unknown(agent_id))
        {:noreply, %{state | binders: rest}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:launch_timeout, tool_use_id}, state) do
    case state.launching do
      %{^tool_use_id => attempt} ->
        log(attempt.run_id, %{
          "broker" => "launch timed out",
          "case" => attempt.case,
          "tool_use_id" => tool_use_id
        })

        {:noreply, requeue(state, tool_use_id)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _, :process, worker, _}, state), do: {:noreply, drop(state, worker)}

  defp take(state, event, from) do
    [attempt | rest] = state.waiting
    tool_use_id = event["tool_use_id"]

    if get_in(event, ["tool_input", "subagent_type"]) == attempt.agent do
      send(attempt.worker, :eab_launching)
      timer = Process.send_after(self(), {:launch_timeout, tool_use_id}, launch_timeout())

      log(attempt.run_id, %{
        "broker" => "claimed",
        "case" => attempt.case,
        "tool_use_id" => tool_use_id
      })

      GenServer.reply(from, {:ok, attempt})
      attempt = Map.put(attempt, :launch_timer, timer)

      {:noreply,
       %{state | waiting: rest, launching: Map.put(state.launching, tool_use_id, attempt)}}
    else
      GenServer.reply(
        from,
        {:deny,
         "This run's solver is subagent_type \"#{attempt.agent}\". Call the Agent tool again with that subagent_type."}
      )

      {:noreply, state}
    end
  end

  # Registered workspaces answer the oldest waiting Agent calls, one each.
  defp wake(%{pollers: [{from, event, timer} | rest], waiting: [_ | _]} = state) do
    Process.cancel_timer(timer)
    {:noreply, state} = take(%{state | pollers: rest}, event, from)
    wake(state)
  end

  defp wake(state), do: state

  defp requeue(state, tool_use_id) do
    {attempt, launching} = Map.pop(state.launching, tool_use_id)
    attempt = Map.delete(attempt, :launch_timer)
    send(attempt.worker, :eab_requeued)
    wake(%{state | launching: launching, waiting: [attempt | state.waiting]})
  end

  defp answer_binders(state, agent_id) do
    {ready, rest} = Enum.split_with(state.binders, fn {_, id, _} -> id == agent_id end)

    for {from, _, timer} <- ready do
      Process.cancel_timer(timer)
      GenServer.reply(from, {:ok, state.active[agent_id].worker})
    end

    %{state | binders: rest}
  end

  # A claimed call whose subagent is never reported goes back to the queue after this.
  defp launch_timeout, do: Application.get_env(:eab, :claude_code_launch_timeout_ms, 120_000)

  # A tool call may arrive just before PostToolUse binds its subagent.
  defp bind_wait, do: Application.get_env(:eab, :claude_code_bind_wait_ms, 30_000)

  defp unknown(agent_id),
    do:
      {:error,
       "No benchmark attempt belongs to solver #{agent_id}. These tools work only for a solver started by /solve-run."}

  # Solvers launching or running; a stopped one awaiting its transcript no longer counts.
  defp working(state),
    do: map_size(state.launching) + Enum.count(state.active, fn {_, a} -> !a[:stopping] end)

  defp attempts(state),
    do: state.waiting ++ Map.values(state.launching) ++ Map.values(state.active)

  defp drop(state, worker) do
    {gone, waiting} = Enum.split_with(state.waiting, &(&1.worker == worker))

    {launching_gone, launching} =
      Map.split_with(state.launching, fn {_, a} -> a.worker == worker end)

    {active_gone, active} = Map.split_with(state.active, fn {_, a} -> a.worker == worker end)

    for attempt <- gone ++ Map.values(launching_gone) ++ Map.values(active_gone) do
      Process.demonitor(attempt.monitor, [:flush])
      if attempt[:launch_timer], do: Process.cancel_timer(attempt.launch_timer)
    end

    %{state | waiting: waiting, launching: launching, active: active}
  end

  defp summary(response) when is_map(response),
    do: Map.take(response, ~w(status isAsync agentId error))

  defp summary(response), do: response && inspect(response, limit: 10, printable_limit: 200)

  # One line per broker decision, beside the run's other evidence.
  defp log(run_id, record) do
    path = Store.path("runs/#{run_id}/claude-code-hooks.jsonl")
    File.mkdir_p!(Path.dirname(path))
    at = DateTime.utc_now() |> DateTime.to_iso8601()
    File.write!(path, Jason.encode!(Map.put(record, "at", at)) <> "\n", [:append])
  rescue
    error -> Logger.warning("Claude Code hook log failed: #{Exception.message(error)}")
  end
end
