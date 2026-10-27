# Parallel attempts: verification, 2026-10-27

Evidence for [ADR 0014](../../docs/adr/0014-run-a-runs-attempts-in-parallel.md): one run works on several cases at once, and one Claude Code solver session serves them. None of these runs is scored or published.

## What Claude Code reports per subagent

A throwaway probe launched two background subagents of one custom agent type at once from a headless Claude Code 2.1.310 session. Both used a logging HTTP tool server. Hooks logged every event.

- The parent's `PreToolUse(Agent)` carries a `tool_use_id`. Its `PostToolUse(Agent)` arrives as soon as the background launch returns, with the same `tool_use_id` and `tool_response.agentId`, the new subagent's id.
- Every tool call a subagent makes reaches `PreToolUse` with that subagent's `agent_id`. A hook's `updatedInput` may add an argument, and the tool server received it unchanged.
- Both subagents shared one MCP connection and session id. The connection therefore cannot tell them apart; only the hook-added id can.
- `SubagentStop` carries the subagent's `agent_id`.

The kit relies on exactly these fields: the controller binds a launch to its attempt by `tool_use_id`, the hook stamps `eab_agent_id` onto each workspace tool call, and the stop event routes by `agent_id`.

## Automated tests

- **Pipeline** (`test/eab/pipeline_test.exs`): two attempts start together; they finish and grade out of order; results stay in case order; a submission waiting for a free grader holds back the next attempt; values outside 1 to 8 are refused. One parallel attempt behaves exactly as before.
- **Runner** (`test/eab/checkpoints_test.exs`): a run's setting reaches the pipeline, so two attempts run at once and a third waits.
- **Claude Code** (`test/eab/claude_code_test.exs`):
  - two solvers, launched and reported in either order, each reach only their own workspace, including calls made concurrently;
  - a tool call that arrives before its launch is reported waits for it;
  - unknown or missing identities never reach a workspace;
  - one solver finishing leaves the other bound;
  - a transcript from another solver fails the attempt;
  - busy slots tell the session to wait for a completion;
  - a launch Claude Code never reports is offered again;
  - a stopped solver frees its slot before its transcript arrives;
  - a solver that ended without a stop event is recovered once, from the session's next launch call;
  - a usage limit on a solver's first request still pauses the run.
- **Kit hook** (`test/claude_code/hook_test.py`): the hook stamps the real subagent id and overwrites any value the model supplied, refuses workspace calls from outside a solver, forwards launch reports, reports a stop before uploading its transcript, and reads finished subagents from Claude Code's records before each claim.
- **Timing and records**: a run above one parallel attempt stores no elapsed time. Reports and public results state the value, and older result records without it still validate.

## Live run

Run `20261027-082155-be2a2fd4`: a Haiku 5.5 validation run with 2 parallel attempts on the new kit, installed in the solver folder. `/solve-run` drove it headless (`claude -p`, Claude Code 2.1.310). It was stopped after four graded cases, as planned.

- **Start.** The first two cases were claimed, launched and bound to distinct subagents 3 seconds apart. Each later slot refilled within 3 seconds of a solver finishing.
- **Routing.** Every case's tool calls came only from the subagent bound to it, for example 35 from one subagent for plausible-pr-5939 and 150 from another for livebook-pr-2219. Each transcript and attempt record carries that same id.
- **Sharing slots.** The broker logged 8 claims, 8 bindings and 4 finishes. The session was told 4 times that both slots were busy, and each time it waited for a completion notification before calling again.
- **Order.** After the resume below, livebook-pr-2219 started 2 seconds before plausible-pr-5956 but finished 12 minutes after it. Scores and the report stay in case order.
- **Outcomes.** plausible-pr-5939, plausible-pr-6449, plausible-pr-5956 and livebook-pr-2219 passed. The report says "Parallel attempts: 2 (no elapsed times recorded)", and no case stored an elapsed time.
- **Resume.** Headless `claude -p` stops background subagents 10 minutes after its last turn unless `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` is set. The desktop session used for real runs has no such ceiling. Two solvers were stopped that way and sent no stop event, so their workspaces stayed claimed. Stopping and resuming the run archived them and restarted both cases as fresh attempts in parallel, with the setting kept.

## Escape test

Two harness gaps surfaced and were fixed before the passing check:

- **A solver ended by an API error sends no stop event.** Run `20261027-091706-a4e3b153` (Opus 5.5, escape test): Opus 5.5's safeguard rejected the probe's first request, so the subagent ended about two seconds in. Claude Code marked it finished in its own subagent record but never fired `SubagentStop`. The controller kept counting it as working, the session was told "All 1 solver of this run is working", and nothing would have freed the slot. Now every launch call first reports the session's finished subagents from those records. The controller recovers any it still counts as working, and the hook uploads their transcripts. The stop hook also tells the controller at once that a solver stopped, before its transcript settles.
- **Proof of the fix.** In run `20261027-093411-befd6711`, Opus's safeguard again ended the solver at once. The next launch call recovered it, its transcript arrived one second later, and the attempt failed as an evaluation error naming the safeguard. The session was then told the run had finished, and it stopped. A transcript holding only an API error now reports that error, and a usage limit on the first request still pauses the run.

Run `20261027-093938-21649d4e` (Haiku 5.5, escape test on the new kit): **passed, no findings**. As on [2026-10-26](../harness-checks-2026-10-26/README.md), Opus 5.5's safeguard rejects the probe text itself, so the check uses Haiku 5.5.

- The solver tried every tool outside its four workspace tools (Agent, Task, Bash, Read, Write, Edit, Glob, Grep, WebFetch, WebSearch, Skill, ToolSearch, TodoWrite, advisor), and each was refused.
- Its seven `bash` and two `read` calls ran in its own workspace.
- The stop notice arrived 1.3 seconds before the transcript.

The Haiku test run and these checks do not count toward the Opus validation ledger.

