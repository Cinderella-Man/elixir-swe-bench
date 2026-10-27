# Run a run's attempts in parallel

A run may work on several cases at once. **Parallel attempts** is a run setting, 1 by default: when a run starts, that many cases start, and another starts as each finishes. It exists for hosted models such as Claude and ChatGPT, where the model provider serves concurrent requests, and for validating new cases faster; a full validation run of twenty cases otherwise takes hours. Runs against a single local model server stay at 1, because concurrent requests would share its GPUs.

Each attempt keeps its own workspace and service containers, so an outcome does not depend on what ran beside it. Cases start in inventory order and may finish in any order; scores, reports and results stay in inventory order. Preparation, waiting workspaces and grading scale with the setting: a run with N parallel attempts prepares at least N cases ahead, holds up to N waiting workspaces and grades up to N submissions at once. The value is recorded on the run and shown with its results. It is not part of a run series' identity, because concurrency does not change what a model can solve.

Elapsed attempt time is recorded only when parallel attempts is 1. Concurrent attempts compete for the controller's CPU while running project tests, and for a local server's slots, so their times are not comparable. Runs above 1 keep token accounting and state that no times were recorded.

The Claude Code harness serves several attempts from the one solver session and the one `/solve-run` command. The kit does not know the setting: it keeps launching background solver subagents while the controller has workspaces ready and waits for one to finish when none is. Each subagent's tool calls reach the controller tagged with Claude Code's per-subagent `agent_id`, which the controller binds to one attempt; tool calls, the stop event and the transcript route by that identity. Because the kit changed, attempts before and after this change belong to different harness identities. Under [ADR 0012](0012-rebuild-release-and-validate-with-unpublished-opus-runs.md) all twenty cases therefore collect their two validation passes under the new kit.

This amends [ADR 0004](0004-overlap-preparation-and-grading.md), which kept model conversations serial with one waiting workspace and one grading lane, and [ADR 0010](0010-run-subscription-claude-through-claude-code-harness.md), where one Claude Code attempt runs at a time.

## Considered options

- **Several runs at once instead of several cases per run**: no help for a single validation run, and it would need several solver sessions and a second active-run slot.
- **Several solver sessions, one attempt each**: the same protocol work plus a manual step per session.
- **A fixed number of slot agents in the kit**, each with its own tool address: works without per-subagent identity, but caps the setting and records the slot in the agent name. Kept as the fallback if Claude Code stops reporting `agent_id` on subagent tool calls.
- **Record times for every run and show the setting beside them**: simpler, but invites comparing times taken under different contention.
