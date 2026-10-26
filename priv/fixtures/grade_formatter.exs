defmodule ElixirAgentBenchmark.TrustedFormatter do
  use GenServer

  def init(_opts), do: {:ok, 0}

  def handle_cast({:test_finished, test}, count) do
    state =
      case test.state do
        nil -> "passed"
        {:failed, _} -> "failed"
        {:skipped, _} -> "skipped"
        {:excluded, _} -> "excluded"
        _ -> "unknown"
      end

    identity = Atom.to_string(test.module) <> "::" <> Atom.to_string(test.name)
    # Every record starts on a fresh line: ExUnit's own formatter can print
    # progress dots between any two writes.
    IO.puts("\nEAB_TEST:" <> state <> ":" <> Base.encode64(identity))

    if state == "excluded" do
      tags =
        test.tags
        |> Enum.filter(fn {_key, value} -> value == true end)
        |> Enum.map(fn {key, _value} -> Atom.to_string(key) end)
        |> Enum.sort()
        |> Enum.join(",")

      IO.puts("\nEAB_EXCLUDED_TAGS:" <> Base.encode64(identity) <> ":" <> Base.encode64(tags))
    end

    if state == "failed" do
      {:failed, failures} = test.state

      types = Enum.map_join(failures, ",", &failure_type/1)
      phase = if Enum.any?(failures, &setup_failure?/1), do: "setup", else: "test"

      IO.puts("\nEAB_FAILURE_TYPES:" <> Base.encode64(identity) <> ":" <> Base.encode64(types))
      IO.puts("\nEAB_FAILURE_PHASE:" <> Base.encode64(identity) <> ":" <> phase)
    end
    {:noreply, count + 1}
  end

  def handle_cast({:suite_finished, _timings}, count) do
    IO.puts("\nEAB_SUITE_FINISHED:" <> Integer.to_string(count))
    {:noreply, count}
  end

  def handle_cast(_event, count), do: {:noreply, count}

  defp failure_type({_kind, %{__struct__: module}, _stack}), do: Atom.to_string(module)
  defp failure_type({_kind, {%{__struct__: module}, _nested_stack}, _stack}), do: Atom.to_string(module)
  defp failure_type({kind, _reason, _stack}) when is_atom(kind), do: Atom.to_string(kind)
  defp failure_type({{:EXIT, _pid}, _reason, _stack}), do: "exit"
  defp failure_type(_failure), do: "unknown"

  defp setup_failure?({_kind, reason, stack}) do
    nested = case reason do
      {_exception, frames} when is_list(frames) -> frames
      _ -> []
    end

    Enum.any?(stack ++ nested, fn
      {_module, function, _arity, _location} when is_atom(function) ->
        name = Atom.to_string(function)
        String.starts_with?(name, "__ex_unit_setup") or name in ["exec_test_setup", "run_setup_all"]
      _ -> false
    end)
  end
  defp setup_failure?(_failure), do: true
end
