# Specify feature cases with grilled specs and allow curator extensions

New feature cases give the solver a grilled spec instead of the shortest sufficient ticket. A grilled spec is the document a developer would hold after a clarifying interview. It covers:

- the goal;
- every decided behaviour, with examples;
- edge cases and error behaviour;
- scope and non-goals;
- compatibility constraints;
- the public interface the feature exposes.

It excludes implementation steps, internal design, file lists, reference code and the upstream PR number.

The spec lives in `ticket.md`. `grading.requirements` stays a short list of key outcomes mapped to checks, because every requirement is appended to the prompt. This matches what an AI agent actually receives after clarification, and naming the public interface is fair because the hidden tests must call it. Existing bug-fix cases keep issue-style tickets plus their explicit requirement lines.

A feature case may extend its upstream PR into a fuller, coherent feature. The curator commits the upstream change plus the extension on the reference branch in the user's fork and writes the hidden tests. Provenance records the upstream PR and the curator extension separately. The extension must follow the project's style and pass the project's full existing suite. It goes through the same independent review, three qualification rounds and two Opus validations as any other case.

For feature cases, this amends [ADR 0009](0009-validate-minimal-tasks-with-blind-model-attempts.md) and the minimal-ticket rule in the [selection guidelines](../pr-selection-guidelines.md).

## Considered options

- **Shortest sufficient ticket**: tests whether the solver guesses product decisions more than whether it implements them, and is unlike how agents receive work after clarification.
- **The full spec repeated in requirement lines**: duplicates the prompt.
- **Features limited to what one upstream PR contained**: caps the size and coherence of feature cases at whatever the PR happened to cover.
