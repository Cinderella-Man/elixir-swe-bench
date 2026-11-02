defmodule Eab.LogSectionsTest do
  use ExUnit.Case, async: true
  alias Eab.{Command, LogSections, TestAdapter}

  @run "mix test test/a_test.exs"

  # Built with the grader's own command format, so a change to it fails here first.
  defp note(text), do: "\n[10:00:00 UTC] #{text}\n"

  defp command(inner) do
    "$ " <>
      Enum.map_join(
        ~w(docker exec -w /workspace eab-1 timeout -k 5 300 bash -lc) ++ [inner],
        " ",
        &Command.quote/1
      )
  end

  defp tests(states) do
    Enum.map_join(states, fn {state, count} ->
      Enum.map_join(1..count//1, fn n ->
        "\nEAB_TEST:#{state}:#{Base.encode64("#{state}#{n}")}\n"
      end)
    end)
  end

  defp run(states, code, adapter \\ "exunit", test \\ @run) do
    note(command(TestAdapter.command(adapter, test, []))) <>
      tests(states) <> note("Process exited with code #{code}")
  end

  defp setup_command(text), do: note(command(text)) <> note("Process exited with code 0")

  defp agent do
    note("Preparing case-1") <>
      note("Reusing checked fixture for case-1") <>
      note("Starting workspace and services for case-1") <>
      note("Workspace ready for Pi") <>
      note("Starting Pi for case-1") <>
      note("Starting Pi 1.2.0 in eab-1, working directory /workspace") <>
      note("Pi is using bash") <>
      note("Submission saved; waiting for grading")
  end

  defp labels(log, kind \\ nil), do: log |> LogSections.split(kind) |> Enum.map(& &1.label)

  defp section(log, label), do: log |> LogSections.split() |> Enum.find(&(&1.label == label))

  test "a graded case splits into its stages, and coverage failures are expected" do
    log =
      agent() <>
        note("Grading case-1") <>
        setup_command("git apply --whitespace=nowarn submission.patch") <>
        run([passed: 5], 0) <>
        setup_command("git apply --whitespace=nowarn acceptance.patch") <>
        run([passed: 3, excluded: 1], 0) <>
        run([passed: 4], 0) <>
        setup_command("git apply --whitespace=nowarn tests.patch") <>
        run([passed: 2, failed: 3], 2) <>
        note("$ 'docker' 'rm' '-f' '-v' 'eab-1'") <>
        "Error response from daemon: No such container: eab-1\n" <>
        note("Process exited with code 0")

    assert labels(log) == [
             "Preparation",
             "Workspace",
             "Pi attempt",
             "Grading · Submitted tests",
             "Grading · Acceptance",
             "Grading · Preservation",
             "Grading · Regression coverage",
             "Grading · Cleanup"
           ]

    assert %{result: "5 tests, 0 failed", tone: "passed", expected_failures: false} =
             section(log, "Grading · Submitted tests")

    assert %{result: "3 tests, 0 failed, 1 excluded", tone: "passed"} =
             section(log, "Grading · Acceptance")

    assert %{result: "5 tests, 3 failed", tone: "pending", expected_failures: true} =
             section(log, "Grading · Regression coverage")

    sections = LogSections.split(log)
    assert Enum.map(sections, & &1.index) == Enum.to_list(0..7)

    # Each test keeps the commands that set it up, and cleanup noise stays out of it.
    acceptance = LogSections.body(log, section(log, "Grading · Acceptance"))
    assert acceptance =~ "acceptance.patch"
    refute acceptance =~ "submission.patch"
    refute LogSections.body(log, section(log, "Grading · Regression coverage")) =~ "No such"
    assert LogSections.body(log, section(log, "Grading · Cleanup")) =~ "No such container"

    assert Enum.sum(Enum.map(sections, & &1.size)) == byte_size(log)
  end

  test "failed scored checks are marked, and a run with no coverage stops at preservation" do
    log =
      agent() <>
        note("Grading case-1") <>
        run([passed: 4, failed: 1], 2) <> run([passed: 2], 0) <> run([passed: 3], 0)

    assert %{result: "5 tests, 1 failed", tone: "failed"} =
             section(log, "Grading · Submitted tests")

    assert %{tone: "passed"} = section(log, "Grading · Preservation")
    refute section(log, "Grading · Regression coverage")
    refute section(log, "Grading · Cleanup")
  end

  test "a test run that could not compile reports its exit code" do
    log =
      note("Grading case-1") <>
        note(command(TestAdapter.command("exunit", @run, []))) <>
        "** (CompileError) test/a_test.exs\n" <> note("Process exited with code 1")

    assert %{result: "Exited with code 1", tone: "failed"} =
             section(log, "Grading · Submitted tests")
  end

  test "each file probe that follows a stopped coverage run names its file" do
    log =
      note("Grading case-1") <>
        run([passed: 2], 0) <>
        run([passed: 1], 0) <>
        run([passed: 1], 0) <>
        run([], 1) <>
        run([], 1, "exunit", "mix test test/a_test.exs") <>
        run([passed: 2, failed: 1], 1, "exunit", "mix test test/b_test.exs")

    assert %{result: "Exited with code 1", tone: "pending"} =
             section(log, "Grading · Regression coverage")

    assert %{result: "Exited with code 1", tone: "pending", expected_failures: true} =
             section(log, "Grading · Regression coverage: test/a_test.exs")

    assert %{result: "3 tests, 1 failed", tone: "pending", expected_failures: true} =
             section(log, "Grading · Regression coverage: test/b_test.exs")
  end

  test "node test runs are recognised, and a formatter install is not a test run" do
    log =
      note("Grading case-1") <>
        setup_command(
          "mkdir -p '/opt/eab-grade' && rm -f '/opt/eab-grade/node_runner.mjs' && head -c 12 > '/opt/eab-grade/node_runner.mjs'"
        ) <>
        run([passed: 1], 0, "node", "node --test test/a.mjs") <>
        run([passed: 2], 0, "node", "node --test test/a.mjs") <>
        run([passed: 3], 0, "node", "node --test test/a.mjs") <>
        run([passed: 2, failed: 1], 1, "node", "node --test test/a.mjs")

    assert labels(log) == [
             "Grading · Submitted tests",
             "Grading · Acceptance",
             "Grading · Preservation",
             "Grading · Regression coverage"
           ]

    assert %{result: "1 test, 0 failed"} = section(log, "Grading · Submitted tests")
  end

  test "a refactor's added tests must pass, so their failures are not expected" do
    log =
      note("Grading case-1") <>
        run([passed: 1], 0) <>
        run([passed: 1], 0) <> run([passed: 1], 0) <> run([passed: 1, failed: 1], 2)

    assert "Grading · Added contract tests" in labels(log, "refactor")

    assert %{tone: "failed", expected_failures: false} =
             log |> LogSections.split("refactor") |> List.last()
  end

  test "a test still running, or stopped, has no result yet" do
    log =
      note("Grading case-1") <>
        run([passed: 1], 0) <> note(command(TestAdapter.command("exunit", @run, []))) <> ".\n"

    assert %{label: "Grading · Acceptance", result: "Not finished", tone: "pending"} =
             log |> LogSections.split() |> List.last()
  end

  test "commands between tests take the next test's place once it starts" do
    between = note("Grading case-1") <> run([passed: 1], 0) <> setup_command("git reset -q HEAD")

    assert [_, %{index: 1, label: "Grading · Cleanup"}] = LogSections.split(between)

    assert [_, %{index: 1, label: "Grading · Acceptance"}] =
             LogSections.split(between <> run([passed: 1], 0))
  end

  test "grader commands outside grading stay in the section they ran in" do
    log = agent() <> note(command(TestAdapter.command("exunit", @run, [])))
    assert List.last(labels(log)) == "Pi attempt"
  end

  test "fixture checks and a resumed attempt get sections of their own" do
    log =
      note("Preparing case-1") <>
        note("Checking broken, reference, bypass and partial repairs for case-1: no saved") <>
        note("Checking broken source for case-1") <>
        note("Checking reference repair for case-1") <>
        note("Checking early-exit rejection for case-1") <>
        note("Checking partial-repair rejection for case-1") <>
        note("Starting Claude Code for case-1") <>
        note("Grading case-1") <>
        run([passed: 1], 0) <>
        note("Starting Claude Code for case-1") <> note("Grading case-1") <> run([passed: 2], 0)

    assert labels(log) == [
             "Preparation",
             "Fixture check: starting source",
             "Fixture check: reference repair",
             "Fixture check: early exit",
             "Fixture check: partial repair",
             "Claude Code attempt",
             "Grading · Submitted tests",
             "Claude Code attempt",
             "Grading · Submitted tests"
           ]
  end

  test "text with no notes is one section, and an empty log has none" do
    log = "$ mix test\nCompiling project"

    assert [%{index: 0, label: "Preparation", result: nil, tone: nil, expected_failures: false}] =
             sections = LogSections.split(log)

    assert LogSections.body(log, hd(sections)) == log
    assert LogSections.split("") == []
    assert LogSections.split("\n\n") == []
  end

  test "a section's body is bounded to its tail and survives a split character" do
    log = String.duplicate("a", 100) <> "é latest"
    [section] = LogSections.split(log)

    assert LogSections.body(log, section, 7) ==
             "[Earlier output omitted; download the full log]\n latest"

    assert LogSections.body(log, section, 8) ==
             "[Earlier output omitted; download the full log]\n� latest"
  end

  test "output that is not valid text still splits and displays" do
    log = note("Preparing case-1") <> <<0xFF, 0xFE>> <> "\nend\n"
    [section] = LogSections.split(log)
    assert String.valid?(LogSections.body(log, section))
    assert LogSections.body(log, section) =~ "end"
  end
end
