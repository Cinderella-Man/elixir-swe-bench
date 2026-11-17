defmodule Eab.EvidenceTest do
  use ExUnit.Case, async: true
  alias Eab.Evidence

  test "named failures and missing preservation checks are compact while raw output is excluded" do
    grade = %{
      "passed" => false,
      "hidden" => %{
        "passed" => false,
        "completed" => true,
        "test_results" => %{"acceptance" => "failed"},
        "output" => String.duplicate("compiling\n", 1000) <> "  1) acceptance\nAssertion failed\n"
      },
      "regression" => %{
        "passed" => false,
        "completed" => true,
        "test_results" => %{},
        "changed_control_states" => %{"old behavior" => "passed"}
      }
    }

    summary = Evidence.summarize(grade)

    assert Enum.at(summary["checks"], 0)["failures"] == [
             %{"name" => "acceptance", "expected" => "passed", "observed" => "failed"}
           ]

    assert Enum.at(summary["checks"], 0)["excerpt"] =~ "Assertion failed"
    refute Jason.encode!(summary) =~ String.duplicate("compiling", 3)

    assert Enum.at(summary["checks"], 1)["failures"] == [
             %{"name" => "old behavior", "expected" => "passed", "observed" => "missing"}
           ]

    assert Evidence.verdict(%{"grade" => summary}) == "Acceptance, Preservation did not pass"
  end

  test "model budget exhaustion does not replace the actual grading verdict" do
    assert Evidence.verdict(%{
             "status" => "completed",
             "stop_reason" => "token_budget",
             "grade" => %{"passed" => true}
           }) == "All required checks passed"

    assert Evidence.verdict(%{"status" => "error", "error" => "service stopped"}) ==
             "Evaluation error"

    summary =
      Evidence.summarize(%{
        "passed" => false,
        "submission" => %{"passed" => false, "completed" => false, "test_results" => %{}}
      })

    assert hd(summary["checks"])["completed"] == false
    assert hd(summary["checks"])["failure_count"] == 0
  end

  test "compact run records preserve verdicts while execution errors override an older verdict" do
    record = %{
      "status" => "completed",
      "calls" => 200,
      "grade" =>
        Evidence.summarize(%{
          "passed" => false,
          "hidden" => %{"passed" => false, "output" => "test output"}
        })
    }

    compact = Evidence.compact(record)
    assert Evidence.verdict(compact) == "Acceptance did not pass"
    assert compact["calls"] == 200
    refute Jason.encode!(compact) =~ "test output"
    refute Map.has_key?(compact["grade"], "checks")
    assert Evidence.compact(compact) == compact
    assert Evidence.verdict(Map.put(compact, "status", "error")) == "Evaluation error"
  end

  test "a token allowance explains itself in the verdict and keeps the patch's own verdict" do
    stopped = "The attempt was stopped at its allowance of 16,384 generated tokens."

    grade = %{
      "passed" => false,
      "patch_passed" => true,
      "artifact" => "case-a/grade.json",
      "artifact_hash" => "hash",
      "checks" => [
        %{"id" => "hidden", "label" => "Acceptance", "passed" => true},
        %{
          "id" => "allowance",
          "label" => "Token allowance",
          "passed" => false,
          "reason" => stopped
        }
      ]
    }

    assert Evidence.verdict(%{"grade" => grade}) ==
             stopped <> " Its patch passed every other check."

    wrong = put_in(grade, ["checks", Access.at(0), "passed"], false)
    assert Evidence.verdict(%{"grade" => wrong}) == "Acceptance did not pass. " <> stopped

    compact = Evidence.compact(%{"case" => "case-a", "status" => "completed", "grade" => grade})
    assert compact["grade"] == Map.delete(grade, "checks")
    assert compact["verdict"] == stopped <> " Its patch passed every other check."
  end
end
