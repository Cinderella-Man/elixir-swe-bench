defmodule Eab.Agent do
  @moduledoc "Harness submission and independent grading, with durable handoff between them."
  alias Eab.{
    Checkpoints,
    ClaudeCode,
    Evidence,
    Grader,
    Inventory,
    Model,
    Pi,
    Sandbox,
    Store,
    TaskContract
  }

  def attempt(id, run_id, endpoint, key, settings, control, emit) do
    submission =
      Sandbox.with_box(id, run_id, &submit(id, run_id, &1, endpoint, key, settings, emit),
        agent: true
      )

    grade(id, run_id, submission, endpoint, key, control, emit)
  rescue
    error -> error(id, run_id, Exception.message(error), key)
  end

  def submit(id, run_id, box, endpoint, key, settings, emit) do
    prefix = "runs/#{run_id}/#{id}"
    spec = Inventory.spec(id)
    prompt = Inventory.file(id, "ticket.md")
    instructions = instructions(spec, settings)
    claude_code = ClaudeCode.harness?(endpoint)

    base = %{
      "case" => id,
      "settings" => settings,
      "agent" => if(claude_code, do: ClaudeCode.identity(endpoint), else: Pi.identity()),
      "agent_image" => box.runtime["image"],
      "calls" => 0,
      "generated_tokens" => 0,
      "status" => "running",
      "model" => endpoint
    }

    Store.write("#{prefix}/attempt.json", base, key)
    Store.write_text("#{prefix}/prompt.md", prompt, key)
    Store.write_text("#{prefix}/instructions.md", instructions, key)

    {record, patch} =
      try do
        run = Store.read("runs/#{run_id}/run.json") || %{}

        result =
          if claude_code do
            # An escape test swaps the task for the frozen probe; nothing else changes.
            escape = get_in(run, ["selection", "kind"]) == "escape_test"

            ClaudeCode.Attempt.run(
              box,
              endpoint,
              key,
              prefix,
              if(escape,
                do: ClaudeCode.escape_prompt(),
                else: ClaudeCode.prompt(instructions, prompt)
              ),
              emit,
              escape_test: escape
            )
          else
            # Concurrent attempts share the host and any local model server, so their
            # elapsed times are not comparable and are not recorded (ADR 0014).
            Pi.run(box, endpoint, key, settings, prefix, prompt, instructions, emit,
              measure: (run["parallel_attempts"] || 1) == 1
            )
          end

        {Map.merge(base, result), Sandbox.patch(box)}
      after
        try do
          Store.write_text("#{prefix}/model.patch", Sandbox.patch(box), key)
        rescue
          _ -> :ok
        end
      end

    Checkpoints.submit(run_id, id, record, patch, key)
  end

  @doc "Pi's exact task instructions; the Claude Code harness sends the same text."
  def instructions(spec, settings) do
    """
    #{TaskContract.instructions(spec)}
    Dependencies are prepared. The workspace is offline. Preserve existing behavior and do not weaken tests.
    #{if Eab.Browser.enabled?(spec), do: "Chromium and Playwright are preinstalled. Node tests can import process.env.EAB_BROWSER_MODULE. Bind any test web server to loopback and close browsers/servers after each suite.", else: ""}
    Allowed edit prefixes: #{Enum.join(spec["allowed_edit_prefixes"], ", ")}.
    When finished, give a short summary. Your current patch is then checked in a fresh workspace.
    #{budget_instructions(settings)}
    History is never compacted. If a budget is exhausted, the current patch is graded.
    Task details: #{Jason.encode!(spec["clarifications"] || %{})}
    """
  end

  def grade(id, run_id, {record, patch}, endpoint, key, control, emit) do
    prefix = "runs/#{run_id}/#{id}"
    Store.write("#{prefix}/attempt.json", Map.put(record, "status", "grading"), key)
    emit.("Grading #{id}")
    grade = Grader.grade(id, patch, run_id, expected: control["reference_patch"])
    Model.unchanged!(endpoint, key)
    summary = Evidence.save(run_id, id, grade, key)
    record = Map.merge(record, %{"status" => "completed", "grade" => summary})
    Checkpoints.complete(run_id, id, record, key) |> Evidence.compact()
  end

  def error(id, run_id, message, key) do
    prefix = "runs/#{run_id}/#{id}"
    Store.write_text("#{prefix}/error.txt", message, key)

    record =
      Store.read("#{prefix}/attempt.json", %{"case" => id})
      |> Map.merge(Store.read("#{prefix}/agent-progress.json", %{}))
      |> Map.merge(%{
        "status" => "error",
        "error" => Store.redact(message, key) |> String.slice(0, 2000)
      })

    Store.write("#{prefix}/attempt.json", record, key)
    Eab.Activity.note("ERROR: " <> record["error"])
    record
  end

  # The Claude Code harness declares the same subscription sentence without enforcing it.
  defp budget_instructions(%{"budget_policy" => policy} = settings)
       when policy in ["response_boundary_soft_limit", "declared_not_enforced"] do
    "Model and tool calls are unlimited. Stop after #{settings["max_tokens"]} generated tokens total, checked between complete responses. A response can exceed the remaining threshold. Context and per-response limits are enforced by the provider."
  end

  defp budget_instructions(settings) do
    "Model and tool calls are unlimited. Limits: #{settings["max_tokens"]} generated tokens total, #{settings["window_tokens"]} context tokens including up to #{settings["response_tokens"]} response tokens."
  end
end
