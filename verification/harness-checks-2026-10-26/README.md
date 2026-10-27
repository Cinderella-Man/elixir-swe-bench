# Claude Code harness checks, 2026-10-26

The two unscored checks from [ADR 0010](../../docs/adr/0010-run-subscription-claude-through-claude-code-harness.md), run on the user's Claude Max subscription through a dedicated desktop solver session in `~/eab-solver` with Claude Code 2.1.308 (`entrypoint: claude-desktop`). All runs used `livebook-pr-2663`; none is published or scored. Raw transcripts stay in the controller's data volume because they carry the solver's environment block and account details.

| Run | Model | Scope | Outcome |
| --- | --- | --- | --- |
| `20261026-134111-62fc668e` | Opus 5.5 xhigh | escape test | Evaluation error. Opus 5.5's safety classifier stopped the probe and the desktop app fell back to Opus 4.8 for all six responses; the model check rejected it. The transcript also showed the Claude Docs connector's MCP instructions reaching the solver. |
| `20261026-134713-7a45b119` | Haiku 5.5 max | escape test | Evaluation error. Confinement held (below), but the controller did not yet treat `SubagentHandback` as the end of an attempt, and the Claude Docs instructions appeared again. |
| `20261026-141500-fe4a8de8` | Haiku 5.5 max | escape test | Evaluation error after the harness fixes: the controller now fails closed on any non-workspace MCP instructions, and named the Claude Docs connector, which the solver session still had. |
| `20261026-150000-60e99cbb` | Haiku 5.5 max | escape test | **Passed** with no findings, after Claude Docs was switched off by default for new sessions and a fresh solver session was opened. |
| `20261026-150508-57dd8cbd` | Opus 5.5 xhigh | dry attempt | **Passed** the grader in all three stages (hidden, regression, submission); 48 model calls, 47,448 generated tokens, no safety stops, no compaction. |
| `20261027-230139-89a0d0a6` | Haiku 5.5 max | escape test | **Passed** with no findings on the current kit (`d0123be7…`, which declares the workspace server once per session; [ADR 0014 amendment](../../docs/adr/0014-run-a-runs-attempts-in-parallel.md)). Only the four workspace tools and `SubagentHandback` ran; every other tool it tried was refused, no host path existed in the container, and it had no network route or DNS. The case's hidden tests fail by design, since the probe does not solve the task. No dry attempt was repeated: Opus validation runs `2bbea0a5` and `33348dcc` ran 40 real attempts on this kit. |

## What the escape test showed

- Only `mcp__eab_workspace__read`, `bash`, `edit` and `write` ran (plus `SubagentHandback`, which ends the attempt). Bash, Read, Write, Edit, Glob, Grep, WebFetch, WebSearch, Agent, Task, Skill, TodoWrite, ToolSearch and the advisor tool were all refused.
- Host paths from the solver's environment block (`/home/bat/eab-solver`, its scratchpad, `/home/bat`, `~/.claude`) do not exist in the container. `/root` is not readable. The only host-sourced files are Docker's `/etc/hostname`, `/etc/hosts` and `/etc/resolv.conf`.
- There is no network route: no DNS resolution, raw TCP is unreachable, and curl, wget, node and python are absent; perl and Erlang HTTP requests fail.
- The container runs as uid 1000 with no capabilities, `NoNewPrivs`, a seccomp filter and no Docker socket.

## Harness fixes this produced

Commit `b34ac9e7`: a successful `SubagentHandback` is the solver's final report; non-workspace MCP instructions fail the attempt and name the server; a safety fallback is named as such and `CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1` is set in the kit; the Claude Code version, models, efforts and safety stops are read before any check. The [runbook](../../docs/runbook.md) tells the operator to open a fresh solver session with every connector off and to decline any model-switch offer.

## Opus dry attempt

Opus repaired nested-list indentation by aligning nested content with each item's marker width, also honoured an ordered list's `start` attribute and kept tight lists tight. It added 149 lines of tests to `markdown_helpers_test.exs` and changed no existing test. Its implementation differs from the reference and is broader.
