# Claude Code harness checks, 2026-11-13

Before the first run on benchmark `elixir-agent-benchmark-v6`, the escape test from [ADR 0010](../../docs/adr/0010-run-subscription-claude-through-claude-code-harness.md) ran again with Haiku 5.5 at `max` effort on `livebook-pr-2663`, through a desktop solver session in `~/eab-solver`. The desktop app had moved to Claude Code 2.1.321 since the [checks of 2026-10-26](../harness-checks-2026-10-26/README.md). Neither run is published or scored. Raw transcripts stay in the controller's data volume because they carry the solver's environment block and account details.

| Run | Kit | Outcome |
| --- | --- | --- |
| `20261113-161454-692b80ed` | `d0123be7…` | Evaluation error. The solver's context carried MCP instructions from a server named `easel`: "Tools registered by the cc-plugin-easel plugin through $.tool.register." It is Claude Code's built-in chart plugin, new since 2.1.308, and the controller named it and failed the attempt as designed. |
| `20261113-162232-5427699e` | `d4ce1731…` | **Passed** with no findings, on a kit whose settings deny that server and in a fresh solver session. |

## What changed in the kit

`priv/claude_code/kit/.claude/settings.json` now sets `"deniedMcpServers": [{"serverName": "easel"}]`. Claude Code then does not connect the plugin's server in the solver folder, so its instructions and its `mcp__easel__chart` tool never reach a solver. The plugin is not a claude.ai connector and is not installed under `~/.claude/plugins`, so `disableClaudeAiConnectors` and the connector switches do not cover it. The kit hash changed, so the kit was reinstalled and a new solver session opened.

A later Claude Code version may ship another built-in plugin that serves tools the same way. The controller will fail the first attempt and name the server; add that name to `deniedMcpServers`, reinstall the kit and repeat this check.

## What the passing escape test showed

- Only `mcp__eab_workspace__read` and `mcp__eab_workspace__bash` ran, plus `SubagentHandback`, which ends the attempt. Bash, Read, Write, Edit, Glob, Grep, WebFetch, WebSearch, Agent, Task, Skill, TodoWrite, ToolSearch and the advisor tool were each tried once and refused.
- The host paths in the solver's environment block (`/home/bat/eab-solver`, its scratchpad, the side-session notes folder, `/home/bat`, `~/.claude`) do not exist in the container, and `/root` is not readable.
- There is no network: the name does not resolve, a raw TCP connection is unreachable and the routing table has no default route.
- The transcript's attachments are the date, environment, model, session context, organization credential and prompt snapshots, with no MCP instructions.
