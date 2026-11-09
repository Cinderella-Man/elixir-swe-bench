defmodule Eab.ReportTest do
  use ExUnit.Case, async: true
  alias Eab.{Report, Store}

  test "reports thinking and synthetic case durations including failed repairs" do
    id = "report-time-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf!(Store.path("runs/#{id}")) end)

    run = %{
      "id" => id,
      "status" => "completed",
      "model" => %{"model" => "fixture", "backend" => "strata"},
      "settings" => Eab.Thinking.settings(%{}, %{"reasoning_effort" => "xhigh"}),
      "cases" => ~w(passed failed legacy),
      "attempts" => %{
        "passed" => %{
          "status" => "completed",
          "grade" => %{"passed" => true},
          "measurement" => %{"attempt_ms" => 1001}
        },
        "failed" => %{
          "status" => "completed",
          "grade" => %{"passed" => false},
          "measurement" => %{
            "attempt_ms" => 2500,
            "model_speed" => %{
              "source" => "server_reported",
              "calls" => 3,
              "prompt_tokens" => 900,
              "prompt_ms" => 1500.0,
              "generated_tokens" => 120,
              "generation_ms" => 6000.0
            }
          }
        },
        "legacy" => %{"status" => "completed", "grade" => %{"passed" => false}}
      }
    }

    Report.write(run)
    report = File.read!(Store.path("runs/#{id}/report.md"))
    assert report =~ "Thinking: xhigh"
    assert report =~ "Thinking source: operator_declared"
    assert report =~ "| passed | Passed | 0 | 1.001 s | Not measured |"

    assert report =~
             "| failed | Failed | 0 | 2.5 s | generation 20.0 tok/s · prompt 600.0 tok/s · " <>
               "reported by llama.cpp over 3 model calls |"

    assert report =~ "| legacy | Failed | 0 | Not measured | Not measured |"

    assert report =~
             "- Model speed: generation 20.0 tok/s · prompt 600.0 tok/s · reported by llama.cpp over 3 model calls\n"
  end

  test "a run's parallel attempts are reported, and parallel runs record no times" do
    id = "report-parallel-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf!(Store.path("runs/#{id}")) end)

    run = %{
      "id" => id,
      "status" => "completed",
      "parallel_attempts" => 3,
      "model" => %{"model" => "fixture", "backend" => "strata"},
      "settings" => %{},
      "cases" => ~w(a),
      "attempts" => %{
        "a" => %{
          "status" => "completed",
          "grade" => %{"passed" => true},
          "measurement" => Eab.Measurement.finish(Eab.Measurement.start(false))
        }
      }
    }

    Report.write(run)
    report = File.read!(Store.path("runs/#{id}/report.md"))
    assert report =~ "- Parallel attempts: 3 (no elapsed times recorded)"

    assert report =~
             "| a | Passed | 0 | Not measured: the run worked on several attempts at once |"

    Report.write(Map.delete(run, "parallel_attempts"))
    assert File.read!(Store.path("runs/#{id}/report.md")) =~ "- Parallel attempts: 1\n"
  end
end
