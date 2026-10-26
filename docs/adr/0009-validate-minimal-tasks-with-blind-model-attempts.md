# Validate minimal tasks with independent checks and blind model attempts

Before using cases for the planned cheaper-model comparison, require fixture qualification, review that scored obligations follow from the minimal ticket and visible project, and two fresh strong-model passes with the same model and settings, without access to reference solutions or hidden checks. The passes supply solvability evidence, while defensible alternative repairs remain valid whenever the visible contract does not choose a specific policy; unexplained failures remain unresolved. This adds validation work but avoids treating accepted solutions as proof that the grader is complete or that every later failure is caused by model quality.

Use the existing Pi execution flow for both subscription and local models. Solvability validation uses ordinary saved runs with generous recorded settings, not a separate runner or validation interface; its results are compared with stricter runs only when their effective resource policies match. Add subscription authentication and model selection to the existing connection controls. The user curates cases toward a benchmark of roughly 100–200 cases; automatic two-pass admission enforcement is not implied by this decision.

Amended by [ADR 0010](0010-run-subscription-claude-through-claude-code-harness.md): subscription Claude models run through a Claude Code harness instead of Pi.

Amended by [ADR 0013](0013-specify-feature-cases-with-grilled-specs.md): feature cases give the solver a grilled spec instead of a minimal ticket.
