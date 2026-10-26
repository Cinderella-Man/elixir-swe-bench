# Opus 5.5 validation, 2026-10-26

Unpublished validation runs under [ADR 0012](../../docs/adr/0012-rebuild-release-and-validate-with-unpublished-opus-runs.md): Opus 5.5 at xhigh effort through the [Claude Code harness](../../docs/adr/0010-run-subscription-claude-through-claude-code-harness.md) on the Claude subscription, with the validation flag set. None of these runs is scored or published.

## Runs

| Run | Scope | Outcome |
| --- | --- | --- |
| `20261026-160718-4102f1f8` | all 20 cases | Stopped after the transcript upload race (fixed in `78a375d8`). plausible-pr-5939 and plausible-pr-5956 had passed. It does not count toward validation: the harness kit changed before the next run, so its attempts do not share frozen inputs with later ones. |
| `20261026-162844-07bb9eac` | all 20 cases | Completed: **19 of 20 passed**. ash-pr-3031 failed. Per-case grade summaries and the sealed patches are in [`run-20261026-162844-07bb9eac/`](run-20261026-162844-07bb9eac/). |

Raw transcripts stay in the controller's data volume: they carry the solver's environment block and account details.

## What the reviews of run 07bb9eac found

Every passing patch was reviewed against its ticket, requirements, reference and hidden tests, by independent reviewers who were given the bundles and run evidence. Every claim they made was checked against the files before anything changed.

- **All 19 passes are genuine.** No solution weakened or deleted an existing test. Every edit stayed inside the allowed prefixes, and no shortcut was found. The model's changes to existing tests (livebook-pr-2800 and absinthe-pr-1176) only add assertions, or apply output changes the ticket requires.
- **ash-pr-3031 failed on a stated requirement.** Opus converted a literal argument once, then let Ash convert it a second time inside a typed comparison. That breaks non-idempotent types (13 of 15 hidden checks pass). Adding the reference's two-line fix on top of the model's patch makes all 15 hidden checks pass. The case is sound. On 2026-10-26 **the user chose to keep it in the release** as an example that frontier models still miss stated behaviour; this is an exception to ADR 0012's drop rule. It gets its second Opus attempt in the next validation run.
- **16 cases had checks or texts that a wrong or partial solution could slip past, or a reference that failed its own requirement.** All were corrected; see [the case fixes](../case-fixes-2026-10-26/README.md). Four needed curator corrections to the reference: livebook-pr-2663, plausible-pr-6449, cachex-pr-341 and vutuv-pr-1759.
- **The grader's trusted formatter could lose a failure-phase, failure-type or excluded-tags record.** It printed those records without a leading newline, so ExUnit's progress dots could land before one and hide it from the parser. That could misjudge starting failures, a model's own tests, or a permitted exclusion. Fixed in `ada3d61c`. It was found when the revised livebook-pr-2663 failed qualification for exactly this reason.

## Validation ledger

A case stays in the release after two reviewed passes under the same frozen inputs (ADR 0012).

- **Unchanged cases** have one reviewed pass from run 07bb9eac and need one more: plausible-pr-5939, plausible-pr-5956, livebook-pr-2822. ash-pr-3031 has one failure and stays by the user's decision.
- **Changed cases** start again with two fresh attempts on their new versions; run 07bb9eac's passes were on the old versions. These are the 16 cases in the case-fix record.
