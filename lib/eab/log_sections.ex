defmodule Eab.LogSections do
  @moduledoc """
  Splits a case's activity log into the stages of its run, so the website can show them apart.

  Grading leaves no marks of its own: the grader is part of the qualification hash, and
  existing logs should read the same way. Its test commands always run in the same order,
  so their position names them. This is a reading aid. Model output is in the log too, so a
  verdict only ever comes from `grade.json`.

  A regression coverage run reads by the grader's own rule: a test that fails on the original
  code inside its body catches the problem the submission fixes.
  """
  alias Eab.Grader

  @tail 131_072
  @note ~r/^\[\d\d:\d\d:\d\d UTC\] (.*)$/m
  @test_command ~r/^\$ 'docker' 'exec' .*'-lc' '(?:elixir -r \/opt\/eab-grade\/formatter\.exs -S |node \/opt\/eab-grade\/node_runner\.mjs )/
  @test_file ~r/'\\''([^']+\.(?:exs|mjs|cjs|js))'\\''/
  @test_record ~r/^EAB_TEST:([a-z]+):/m

  def split(log, kind \\ nil) do
    @note
    |> Regex.scan(log, return: :index)
    |> Enum.reduce(
      %{marks: [mark(0, "Preparation")], tests: nil, running: false},
      fn [{at, size}, {text, length}], state ->
        step(state, binary_part(log, text, length), at, at + size, kind)
      end
    )
    |> Map.fetch!(:marks)
    |> Enum.reverse()
    |> sections(log, kind)
  end

  def body(log, %{start: start, size: size}, limit \\ @tail) do
    omitted = max(size - limit, 0)

    # A byte tail can start in the middle of an encoded character.
    text =
      log
      |> binary_part(start + omitted, size - omitted)
      |> String.replace_invalid()
      |> String.trim_leading("\n")

    if(omitted > 0, do: "[Earlier output omitted; download the full log]\n", else: "") <> text
  end

  defp step(state, note, at, stop, kind) do
    cond do
      label = stage(note) ->
        %{open(state, at, label) | tests: if(label == "Grading", do: 0), running: false}

      is_integer(state.tests) and Regex.match?(@test_command, note) ->
        start_test(state, note, kind)

      state.running and String.starts_with?(note, "Process exited with code ") ->
        finish_test(state, note, stop)

      true ->
        state
    end
  end

  defp stage("Preparing " <> _), do: "Preparation"
  defp stage("Checking broken source for " <> _), do: "Fixture check: starting source"
  defp stage("Checking reference repair for " <> _), do: "Fixture check: reference repair"
  defp stage("Checking early-exit rejection for " <> _), do: "Fixture check: early exit"
  defp stage("Checking partial-repair rejection for " <> _), do: "Fixture check: partial repair"
  defp stage("Starting workspace and services for " <> _), do: "Workspace"
  defp stage("Starting Pi for " <> _), do: "Pi attempt"
  defp stage("Starting Claude Code for " <> _), do: "Claude Code attempt"
  defp stage("Grading " <> _), do: "Grading"
  defp stage(_), do: nil

  defp open(%{marks: [%{label: label} | _]} = state, _, label), do: state
  defp open(state, at, label), do: %{state | marks: [mark(at, label) | state.marks]}

  # The commands that set a test up run after the previous one exits. They belong to the
  # test they prepare, so the running test takes over the mark left open by the last one.
  defp start_test(%{marks: [mark | marks]} = state, note, kind) do
    check = check(state.tests, note, kind)

    %{state | marks: [Map.merge(mark, check) | marks], tests: state.tests + 1, running: true}
  end

  defp finish_test(%{marks: [mark | marks]} = state, note, stop) do
    "Process exited with code " <> code = note

    %{
      state
      | marks: [mark(stop, "Grading · Cleanup"), %{mark | exit: code} | marks],
        running: false
    }
  end

  defp check(0, _, _), do: %{label: "Grading · Submitted tests", check: :scored}
  defp check(1, _, _), do: %{label: "Grading · Acceptance", check: :scored}
  defp check(2, _, _), do: %{label: "Grading · Preservation", check: :scored}
  defp check(3, _, "refactor"), do: %{label: "Grading · Added contract tests", check: :scored}
  defp check(3, _, _), do: %{label: "Grading · Regression coverage", check: :expected_failures}

  # One submitted test file that cannot compile stops the whole probe, so each file then
  # runs alone.
  defp check(_, note, _) do
    file =
      case Regex.run(@test_file, note) do
        [_, file] -> ": " <> String.replace_invalid(file)
        nil -> ""
      end

    %{label: "Grading · Regression coverage" <> file, check: :expected_failures}
  end

  defp mark(start, label), do: %{label: label, start: start, check: nil, exit: nil}

  defp sections(marks, log, kind) do
    stops = Enum.map(tl(marks), & &1.start) ++ [byte_size(log)]

    marks
    |> Enum.zip(stops)
    |> Enum.map(fn {mark, stop} -> Map.put(mark, :size, stop - mark.start) end)
    |> Enum.filter(&Regex.match?(~r/\S/, binary_part(log, &1.start, &1.size)))
    |> Enum.with_index(fn section, index ->
      {result, tone} = result(section, binary_part(log, section.start, section.size), kind)

      section
      |> Map.take([:label, :start, :size])
      |> Map.merge(%{
        index: index,
        result: result,
        tone: tone,
        expected_failures: section.check == :expected_failures
      })
    end)
  end

  defp result(%{check: nil}, _, _), do: {nil, nil}
  defp result(%{exit: nil}, _, _), do: {"Not finished", "pending"}

  # Failures are the point here, so the count of tests that catch the problem is the result.
  defp result(%{check: :expected_failures} = section, body, kind) do
    probe = Grader.parse(%{"output" => body, "output_truncated" => false})
    ran = Enum.count(probe["test_results"], fn {_, state} -> state != "excluded" end)
    caught = length(Grader.behavioral_failures(probe))
    problem = if kind == "feature", do: "the missing feature", else: "the bug"

    cond do
      probe["test_results"] == %{} ->
        {"Tests could not run (exit code #{section.exit})", "failed"}

      not probe["completed"] ->
        {"Tests did not finish (exit code #{section.exit})", "failed"}

      caught == 0 ->
        {"No test catches #{problem}", "failed"}

      caught == 1 ->
        {"1 of #{test_count(ran)} catches #{problem}", "passed"}

      true ->
        {"#{caught} of #{test_count(ran)} catch #{problem}", "passed"}
    end
  end

  defp result(section, body, _) do
    tests =
      Regex.scan(@test_record, body, capture: :all_but_first)
      |> List.flatten()
      |> Enum.frequencies()

    clean = section.exit == "0" and Enum.all?(Map.keys(tests), &(&1 in ~w(passed excluded)))
    {summary(tests, section.exit), if(clean, do: "passed", else: "failed")}
  end

  defp summary(tests, code) when map_size(tests) == 0, do: "Exited with code #{code}"

  defp summary(tests, _) do
    excluded = tests["excluded"] || 0
    ran = Enum.sum(Map.values(tests)) - excluded

    "#{test_count(ran)}, #{tests["failed"] || 0} failed" <>
      if(excluded > 0, do: ", #{excluded} excluded", else: "")
  end

  defp test_count(1), do: "1 test"
  defp test_count(count), do: "#{count} tests"
end
