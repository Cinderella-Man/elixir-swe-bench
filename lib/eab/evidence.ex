defmodule Eab.Evidence do
  @moduledoc "Compact factual verdicts with full grading output retained as a separate artifact."
  alias Eab.{Inventory, Store}

  @dimensions [
    {"hidden", "Acceptance"},
    {"regression", "Preservation"},
    {"submission", "Submitted tests"},
    {"regression_coverage", "Regression coverage"}
  ]

  def save(run_id, id, grade, key) do
    path = "runs/#{run_id}/#{id}/grade.json"
    Store.write(path, grade, key)

    grade
    |> summarize()
    |> Map.put("artifact", "#{id}/grade.json")
    |> Map.put("artifact_hash", Inventory.hash_file(Store.path(path)))
  end

  def summarize(grade) do
    checks =
      for {field, label} <- @dimensions, is_map(grade[field]) do
        result = grade[field]
        tests = result["test_results"] || %{}
        changed = result["changed_control_states"] || %{}

        failures =
          for(
            {id, state} <- tests,
            state in ["failed", "invalid", "skipped"],
            do: %{"name" => id, "expected" => "passed", "observed" => state}
          ) ++
            for {id, expected} <- changed,
                do: %{"name" => id, "expected" => expected, "observed" => tests[id] || "missing"}

        failures = Enum.uniq_by(failures, & &1["name"]) |> Enum.sort_by(& &1["name"])

        %{
          "id" => field,
          "label" =>
            if(field == "regression_coverage" and result["policy"] == "preservation",
              do: "Added contract tests",
              else: label
            ),
          "passed" => result["passed"] == true,
          "completed" => result["completed"],
          "test_count" => map_size(tests),
          "failure_count" => length(failures),
          "failures" => Enum.take(failures, 8),
          "reason" => result["reason"],
          "excerpt" =>
            if(result["passed"] != true,
              do:
                excerpt(
                  result["output"] || get_in(result, ["test_probe", "output"]) ||
                    get_in(result, ["broken_test_probe", "output"])
                )
            )
        }
      end

    %{
      "passed" => grade["passed"] == true,
      "reason" => grade["reason"],
      "checks" => checks,
      "submitted_test_files" => grade["submitted_test_files"] || []
    }
  end

  def verdict(nil), do: "Not attempted"
  def verdict(%{"status" => "error"}), do: "Evaluation error"

  def verdict(%{"status" => status}) when status in ["cancelled", "interrupted"],
    do: "Attempt interrupted"

  def verdict(%{"grade" => %{"passed" => true}}), do: "All required checks passed"
  def verdict(%{"verdict" => verdict}) when is_binary(verdict), do: verdict

  def verdict(%{"grade" => grade}) when is_map(grade) do
    grade = if grade["checks"], do: grade, else: summarize(grade)
    failed = Enum.reject(grade["checks"], & &1["passed"])

    cond do
      grade["reason"] -> "Submission rejected: #{grade["reason"]}"
      failed != [] -> Enum.map_join(failed, ", ", & &1["label"]) <> " did not pass"
      true -> "Required checks did not pass"
    end
  end

  def verdict(attempt), do: String.capitalize(attempt["status"] || "Pending")

  def checks(attempt) do
    case attempt && attempt["grade"] do
      nil -> []
      %{"checks" => checks} -> checks
      grade -> summarize(grade)["checks"]
    end
  end

  def links(run_id, case_id) do
    for {file, label} <- [
          {"model.patch", "Submitted patch"},
          {"grade.json", "Full grading evidence"},
          {"error.txt", "Full evaluation error"},
          {"provider-error.json", "Provider error details"},
          {"pi-events.jsonl", "Pi trajectory"},
          {"claude-transcript.jsonl", "Claude Code transcript"},
          {"claude-tool-calls.jsonl", "Workspace tool calls"},
          {"harness-prompt.md", "Harness prompt"},
          {"attempt.json", "Attempt and usage"},
          {"submission.json", "Saved submission receipt"},
          {"qualification.json", "Baseline qualification"},
          {"runtime.json", "Environment identity"},
          {"activity.log", "Full activity log"},
          {"build.log", "Preparation log"}
        ],
        path = "#{case_id}/#{file}",
        match?({:ok, _}, Store.artifact(run_id, path)),
        do: %{"path" => path, "label" => label}
  end

  def compact(nil), do: nil

  def compact(record) do
    summary =
      Map.take(
        record,
        ~w(case status calls generated_tokens stop_reason error generation experiment_id interrupted_stage measurement usage claude_code)
      )

    summary = Map.put(summary, "verdict", verdict(record))

    if is_map(record["grade"]),
      do: Map.put(summary, "grade", Map.take(record["grade"], ~w(passed artifact artifact_hash))),
      else: summary
  end

  defp excerpt(nil), do: nil

  defp excerpt(output) do
    lines = String.split(output, "\n")

    start =
      Enum.find_index(
        lines,
        &Regex.match?(~r/(^\s*\d+\)|\*\* \(|\b(error|Error|FAILED|Assertion)\b)/, &1)
      ) || 0

    lines |> Enum.drop(start) |> Enum.take(16) |> Enum.join("\n") |> String.slice(0, 1800)
  end
end
