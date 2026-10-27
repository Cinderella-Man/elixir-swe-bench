defmodule Eab.Pipeline do
  @moduledoc """
  Attempts in case order, up to `parallel` at once (ADR 0014), with bounded preparation,
  workspace prewarming and grading. With one parallel attempt only one agent works at a time.
  """
  use GenServer
  alias Eab.Command

  def run(cases, callbacks, opts \\ []) do
    unless cases == Enum.uniq(cases), do: raise(ArgumentError, "Duplicate pipeline cases")
    {:ok, pid} = GenServer.start(__MODULE__, {self(), cases, callbacks, opts})
    GenServer.call(pid, :run, :infinity)
  end

  # The coordinator outlives a cancelled runner until every worker and its
  # subprocesses have stopped. Container cleanup must wait for this barrier.
  def await_owner(owner) do
    for {pid, _} <- Registry.lookup(Eab.Commands, {:pipeline, owner}) do
      monitor = Process.monitor(pid)

      receive do
        {:DOWN, ^monitor, :process, ^pid, reason} when reason in [:normal, :noproc] ->
          :ok

        {:DOWN, ^monitor, :process, ^pid, reason} ->
          raise "Pipeline cleanup failed: #{inspect(reason)}"
      after
        60_000 ->
          Process.demonitor(monitor, [:flush])
          raise "Pipeline cleanup watchdog expired"
      end
    end

    Command.await_owner(owner)
    Command.await_scope(owner)
  end

  @impl true
  def init({owner, cases, callbacks, opts}) do
    Registry.register(Eab.Commands, {:pipeline, owner}, nil)
    monitor = Process.monitor(owner)
    lookahead = Keyword.get(opts, :lookahead, 4)
    workers = Keyword.get(opts, :preparation_workers, 2)
    parallel = Keyword.get(opts, :parallel, 1)
    ancestry = Keyword.get(opts, :preparation_plan, %{})

    unless Enum.all?(ancestry, fn {id, earlier} ->
             id in cases and is_list(earlier) and earlier == Enum.uniq(earlier) and
               Enum.all?(earlier, &(&1 in cases and &1 != id)) and
               Enum.all?(earlier, fn parent ->
                 Map.get(ancestry, parent, []) == Enum.take_while(earlier, &(&1 != parent))
               end)
           end),
           do: raise(ArgumentError, "Invalid baseline preparation ancestry")

    unless is_integer(lookahead) and lookahead in 1..12 and is_integer(workers) and
             workers in 1..4,
           do: raise(ArgumentError, "Invalid preparation limits")

    unless is_integer(parallel) and parallel in 1..8,
      do: raise(ArgumentError, "Invalid parallel attempts")

    {:ok,
     %{
       owner: monitor,
       command_scope: owner,
       cases: cases,
       pending: cases,
       callbacks: callbacks,
       lookahead: lookahead,
       workers: workers,
       parallel: parallel,
       ancestry: ancestry,
       baselines: MapSet.new(),
       first_started: false,
       prepared: %{},
       tasks: %{},
       warm: [],
       active: [],
       grading: [],
       submissions: [],
       results: %{},
       from: nil
     }}
  end

  @impl true
  def handle_call(:run, from, state), do: advance(%{state | from: from})

  @impl true
  def handle_info({:workspace_ready, pid}, state) do
    if Enum.any?(state.warm, &(&1.pid == pid)),
      do:
        advance(%{
          state
          | warm: Enum.map(state.warm, &if(&1.pid == pid, do: %{&1 | ready: true}, else: &1))
        }),
      else: {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{task: task, kind: kind, id: id}, tasks} ->
        Process.demonitor(task.ref, [:flush])
        Command.await_owner(task.pid)
        state = %{state | tasks: tasks}
        advance(completed(state, kind, id, result))
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{kind: kind, id: id, task: task}, tasks} ->
        Command.await_owner(task.pid)

        advance(
          completed(
            %{state | tasks: tasks},
            kind,
            id,
            {:error, "Worker stopped: #{inspect(reason)}"}
          )
        )
    end
  end

  @impl true
  def terminate(_, state) do
    # Kill all workers first, then join and drain them. No new Docker command
    # can race with Runs' subsequent label-based container cleanup.
    for {_, %{task: task}} <- state.tasks, do: Process.exit(task.pid, :kill)

    for {_, %{task: task}} <- state.tasks do
      Task.shutdown(task, :brutal_kill)
      Command.await_owner(task.pid)
    end
  end

  defp advance(state) do
    state =
      state
      |> start_grade()
      |> start_workspace()
      |> start_attempt()
      |> start_workspace()
      |> start_preparations()

    if map_size(state.results) == length(state.cases) and map_size(state.tasks) == 0 do
      GenServer.reply(state.from, Enum.map(state.cases, &Map.fetch!(state.results, &1)))
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  defp start_preparations(state) do
    preparing =
      for {_, %{kind: kind, id: id}} <- state.tasks, kind in [:baseline, :prepare], do: id

    window =
      Enum.take(
        state.pending,
        if(state.first_started,
          do: max(state.lookahead, state.parallel),
          else: state.parallel
        )
      )

    window
    |> Enum.reject(&(&1 in preparing or Map.has_key?(state.prepared, &1)))
    |> Enum.map(fn id ->
      next =
        if Map.has_key?(state.callbacks, :baseline) do
          (Map.get(state.ancestry, id, []) ++ [id])
          |> Enum.find(
            &(not MapSet.member?(state.baselines, &1) and not Map.has_key?(state.results, &1))
          )
        end

      if next, do: {:baseline, next}, else: {:prepare, id}
    end)
    |> Enum.uniq()
    |> Enum.reject(fn {_, id} -> id in preparing end)
    |> Enum.take(max(state.workers - length(preparing), 0))
    |> Enum.reduce(state, fn {kind, id}, state ->
      callback = Map.fetch!(state.callbacks, kind)
      launch(state, kind, id, fn -> callback.(id) end)
    end)
  end

  # Waiting workspaces cover the next pending cases in order, up to `parallel` of them.
  # A prepared later case never warms ahead of an unprepared earlier one.
  defp start_workspace(state) do
    warm = MapSet.new(state.warm, & &1.id)

    state.pending
    |> Enum.take(state.parallel)
    |> Enum.reduce_while(state, fn id, state ->
      cond do
        MapSet.member?(warm, id) -> {:cont, state}
        Map.has_key?(state.prepared, id) -> {:cont, warm_workspace(state, id)}
        true -> {:halt, state}
      end
    end)
  end

  defp warm_workspace(state, id) do
    parent = self()
    control = Map.fetch!(state.prepared, id)
    workspace = state.callbacks.workspace
    attempt = state.callbacks.attempt

    state =
      launch(state, :attempt, id, fn ->
        workspace.(id, fn box ->
          send(parent, {:workspace_ready, self()})

          receive do
            :attempt -> attempt.(id, box, control)
          end
        end)
      end)

    {_, %{task: task}} =
      Enum.find(state.tasks, fn {_, job} -> job.kind == :attempt and job.id == id end)

    %{state | warm: state.warm ++ [%{id: id, pid: task.pid, ready: false}]}
  end

  # Attempts start in case order while fewer than `parallel` run. A submission waiting
  # for a free grader holds the next workspace back instead of accumulating work.
  defp start_attempt(
         %{submissions: [], pending: [id | rest], warm: [%{id: id, ready: true} = warm | warming]} =
           state
       ) do
    if length(state.active) < state.parallel do
      send(warm.pid, :attempt)

      start_attempt(%{
        state
        | active: state.active ++ [warm],
          warm: warming,
          pending: rest,
          first_started: true
      })
    else
      state
    end
  end

  defp start_attempt(state), do: state

  defp start_grade(%{submissions: [{id, submission} | rest]} = state) do
    if length(state.grading) < state.parallel do
      control = Map.fetch!(state.prepared, id)
      grade = state.callbacks.grade
      state = launch(state, :grade, id, fn -> grade.(id, submission, control) end)
      start_grade(%{state | grading: state.grading ++ [id], submissions: rest})
    else
      state
    end
  end

  defp start_grade(state), do: state

  defp launch(state, kind, id, fun) do
    scope = state.command_scope

    task =
      Task.Supervisor.async_nolink(Eab.Tasks, fn ->
        Command.with_scope(scope, fn ->
          try do
            {:ok, fun.()}
          rescue
            error -> {:error, Exception.message(error)}
          catch
            kind, reason -> {:error, Exception.format_banner(kind, reason)}
          end
        end)
      end)

    put_in(state.tasks[task.ref], %{task: task, kind: kind, id: id})
  end

  defp completed(state, :baseline, id, {:ok, _}),
    do: %{state | baselines: MapSet.put(state.baselines, id)}

  defp completed(state, :prepare, id, {:ok, control}),
    do: put_in(state.prepared[id], control)

  defp completed(state, :attempt, id, {:ok, submission}) do
    %{
      state
      | active: Enum.reject(state.active, &(&1.id == id)),
        submissions: state.submissions ++ [{id, submission}]
    }
  end

  defp completed(state, :grade, id, {:ok, result}),
    do: record(%{state | grading: List.delete(state.grading, id)}, id, result)

  defp completed(state, kind, id, {:error, message}) do
    state =
      case kind do
        kind when kind in [:prepare, :baseline] ->
          state

        :grade ->
          %{state | grading: List.delete(state.grading, id)}

        :attempt ->
          %{
            state
            | active: Enum.reject(state.active, &(&1.id == id)),
              warm: Enum.reject(state.warm, &(&1.id == id))
          }
      end

    result = state.callbacks.error.(id, message)
    record(%{state | pending: List.delete(state.pending, id)}, id, result)
  end

  defp record(state, id, result) do
    state.callbacks.result.(id, result)

    %{
      state
      | results: Map.put(state.results, id, result),
        prepared: Map.delete(state.prepared, id)
    }
  end
end
