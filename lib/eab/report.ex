defmodule Eab.Report do
  alias Eab.{Evidence, Runner, Store}

  def write(run) do
    score = Runner.score(run)
    model = run["model"] || %{}

    final_score =
      if is_number(score["score_percent"]),
        do: "#{score["score_percent"]}%",
        else:
          if(run["selection"],
            do: "Unavailable: partial run",
            else: "Unavailable: run incomplete or contains errors"
          )

    rows =
      Enum.map_join(run["cases"], "\n", fn id ->
        attempt = get_in(run, ["attempts", id]) || %{}

        outcome =
          case attempt do
            %{"status" => "completed", "grade" => %{"passed" => true}} -> "Passed"
            %{"status" => "completed", "grade" => %{"passed" => false}} -> "Failed"
            _ -> attempt["status"] || "Not attempted"
          end

        "| #{id} | #{outcome} | #{attempt["calls"] || 0} | #{Eab.Measurement.label(attempt["measurement"])} | #{escape(Evidence.verdict(attempt))} |"
      end)

    evidence =
      Enum.map_join(run["cases"], "\n\n", fn id ->
        links =
          Evidence.links(run["id"], id)
          |> Enum.map_join(" · ", &"[#{&1["label"]}](#{&1["path"]})")

        "### #{id}\n\n#{links}"
      end)

    breakdowns =
      Runner.breakdowns(run)
      |> Enum.map_join("\n", fn row ->
        "| #{row["dimension"]} | #{escape(row["value"])} | #{row["passed"]}/#{row["planned"]} | #{row["failed"]} | #{row["pending_or_error"]} |"
      end)

    Store.write_text("runs/#{run["id"]}/report.md", """
    # Benchmark report

    - Run: #{run["id"]}
    - Scope: #{scope(run)}
    - Model: #{escape(Eab.ModelIdentity.label(model))}
    - Model weights: #{Eab.ModelIdentity.size_label(model)}
    - Backend: #{model["backend"] || "Unknown"}
    - Harness: #{Eab.Harness.label(run)}#{if run["validation"], do: "\n- Purpose: case validation run; never published or scored", else: ""}
    - Thinking: #{escape(Eab.Thinking.label(run["settings"]))}
    - Thinking source: #{get_in(run, ["settings", "reasoning_effort_source"]) || if(model["backend"] in ["openai_subscription", "anthropic"], do: "provider request", else: "not recorded")}
    - Release: #{run["release_id"] || "Historical protocol only"}
    - Experiment: #{run["experiment_id"] || "Not sealed"}
    - Resumptions: #{run["resume_count"] || 0}
    - Archived interrupted generations: #{length(run["attempt_history"] || [])}
    - Status: #{run["status"]}
    - Passed: #{score["passed"]}/#{score["planned"]}
    - Failed: #{score["failed"]}
    - Pending or error: #{score["pending_or_error"]}
    - Final score: #{final_score}

    #{escape(run["message"] || "")}

    #{memory(run)}

    Effective settings (subscription thresholds and local strict caps are distinct policies):

    ```json
    #{Jason.encode!(run["settings"] || %{}, pretty: true)}
    ```

    Case time covers Pi startup, model calls and tools through completion, excluding fixture preparation and independent grading. Claude Code attempts store no timing. Missing timings are not reconstructed from logs.

    | Case | Result | Model calls | Case time | Explanation |
    | --- | --- | ---: | ---: | --- |
    #{rows}

    | Group | Value | Passed | Failed | Incomplete/error |
    | --- | --- | ---: | ---: | ---: |
    #{breakdowns}

    Case directories contain command output, Pi or Claude Code transcripts, patches and grading evidence. Infrastructure errors are not scored as failed repairs.

    #{evidence}
    """)
  end

  defp scope(%{"selection" => %{"kind" => "error_retry", "source_run" => id}}),
    do: "Evaluation-error retry of " <> id

  defp scope(%{"selection" => %{"kind" => "case_repeat", "source_run" => id}}),
    do: "Selected-case repeat of " <> id

  defp scope(%{"selection" => %{"kind" => "dry_attempt", "cases" => [id]}}),
    do: "Unscored dry attempt on " <> id

  defp scope(%{"selection" => %{"kind" => "escape_test", "cases" => [id]}}),
    do: "Unscored escape test in the workspace of " <> id

  defp scope(_), do: "Full inventory"

  defp memory(%{"memory" => memory}) when is_map(memory) do
    "Sampled model-service memory peaks: #{escape(Eab.MemoryMonitor.label(memory))}. " <>
      "RAM includes the service's charged page cache. [Summary](memory.json) · [Samples](memory-samples.jsonl)."
  end

  defp memory(_), do: ""

  defp escape(text), do: text |> String.replace("|", "\\|") |> String.replace(~r/[\r\n]+/, " ")
end
