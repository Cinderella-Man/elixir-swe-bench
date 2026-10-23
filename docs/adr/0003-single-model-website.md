# Evaluate one served model through a local website

A local, single-user Elixir website owns setup, preparation, execution and results. The user enters a llama.cpp or Strata endpoint, immediately sees the available model details and starts a run. There is one active run at a time, independent of the browser connection.

Each run preserves its model metadata, settings, results, logs and patches. Restarting the application marks active work as interrupted; a fresh run gets a new identity. This keeps lifecycle and scoring rules explicit.

Endpoint discovery records reported properties without requiring manual artifact pins. Missing and unverified properties remain visible. An alias alone does not verify the exact model artifact.

The benchmark system is Elixir; the coding agent is Pi, installed with a pinned Node runtime inside each problem's Docker image. Pi receives the problem prompt and owns its conversation and tools. An I/O bridge keeps the workspace offline while Elixir forwards model requests, enforces budgets, records evidence and grades the resulting patch in fresh containers.

Amended by [ADR 0010](0010-run-subscription-claude-through-claude-code-harness.md): subscription Claude models run through a Claude Code harness instead of Pi.
