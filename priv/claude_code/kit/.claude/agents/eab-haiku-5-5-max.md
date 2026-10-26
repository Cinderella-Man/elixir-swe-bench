---
name: eab-haiku-5-5-max
description: Elixir Agent Benchmark solver (Haiku 5.5, max effort). Used only by /solve-run.
model: claude-haiku-5-5
effort: max
tools: mcp__eab_workspace__read, mcp__eab_workspace__bash, mcp__eab_workspace__edit, mcp__eab_workspace__write
disallowedTools: Agent, Task, Skill, WebFetch, WebSearch, Bash, Read, Write, Edit, Glob, Grep, NotebookEdit, TodoWrite, ToolSearch
omitClaudeMd: true
mcpServers:
  eab_workspace:
    type: http
    url: __EAB_CONTROLLER_URL__/claude-code/mcp
---
