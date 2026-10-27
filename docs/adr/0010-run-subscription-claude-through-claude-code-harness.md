# Run subscription Claude models through a Claude Code harness

Claude models are benchmarked and used for case validation through the user's Claude subscription, not the per-token Claude API. Pi cannot use that subscription: Anthropic reserves subscription sign-in for Claude Code and its own applications and does not permit routing third-party requests through those credentials, so `Eab.Anthropic` stays an API-key transport. Claude attempts therefore run as Claude Code subagents launched from a dedicated solver session in the desktop app. This amends [ADR 0003](0003-single-model-website.md), where Pi is the only agent, and [ADR 0009](0009-validate-minimal-tasks-with-blind-model-attempts.md), where validation uses the Pi flow.

Claude Code replaces only Pi. The controller still creates the offline workspace, renders Pi's exact instructions and ticket, extracts the submission and grades it with the unchanged grader; Claude Code runs are ordinary saved runs that resume, score and publish like any other. Blindness is enforced rather than requested. The solver session's folder holds no repository, project instructions or memory. The solver agent's only tools reproduce Pi 1.2.0's read, bash, edit and write inside the attempt's container. Forks, built-in agents, web tools and skills are denied, and one attempt runs at a time. The agent file is empty; each attempt's prompt is a frozen harness preamble followed by Pi's exact instructions and ticket. The controller rejects an attempt whose transcript does not begin with that prompt byte for byte, or whose resolved model cannot be read.

Where Claude Code has no equivalent, the harness declares the difference instead of hiding it. No generated-token budget can be enforced, so Pi's 262,144-token sentence is declared but not enforced, and transcript usage above it is flagged rather than failed. Compaction is disabled only if Claude Code honours that for subagents; otherwise compactions are recorded. Usage comes from an undocumented transcript format and is best-effort. Harness is therefore a frozen property of every run and is shown on the results page; runs without a recorded harness used Pi. Comparisons across harnesses confound the model with the harness.

Opus 5.5 at extra-high effort (`claude-opus-5-5`, `xhigh`) through this harness is the only validator for new cases, and curation sessions run on Opus 5.5. Two fresh passes remain the default. Haiku 5.5 is a benchmark subject only: a weaker model's failure does not show that a case is unsolvable. Existing Astra validations keep their evidence. Before the first scored run, an escape test and one unscored Opus attempt on an already validated case check the harness.

## Amendments

- [ADR 0014](0014-run-a-runs-attempts-in-parallel.md) lets one solver session serve several attempts at once; the controller tells them apart by Claude Code's per-subagent `agent_id`.
- The dashboard no longer offers Pi through the per-token Claude API, because subscription runs through this harness are the supported way to benchmark Claude. `Eab.Anthropic` and its tests remain, unused.

## Considered options

- **Pi with the Claude API**: same agent as every other row, but billed per token, which the user rules out.
- **Pi with subscription sign-in**: not permitted for third-party applications.
- **Headless `claude -p` inside the workspace**: subscription-billed with the strongest isolation, but it needs network access from the offline workspace and is not driven from the desktop app.
- **Side scripts that grade a patch and assemble a results file**: less controller work, but they bypass the receipts every published run relies on.
