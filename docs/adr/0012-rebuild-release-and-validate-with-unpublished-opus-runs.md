# Rebuild the release on prepared forks and validate it with unpublished Opus runs

Before any scored run, the fourteen cases are rebuilt so that every case works the same way. Each case gets a prepared baseline branch, a reference branch and a source-pair PR in the user's fork, with every environment change inside the fork instead of an `environment.patch` overlay. Images are pinned by digest. Each case uses the schema-v2 contract, with every scored check stated as a solver-visible requirement, plus an admission receipt, an independent review and three matching qualification rounds. The [freeze audit](../verification/case-freeze-audit-2026-10-26.md) fixes go into the same versions. All earlier runs, releases, qualification records and published results were deleted without an archive on 2026-10-26, because they belong to case versions that are being replaced. Preparation caches and the ChatGPT sign-in were kept.

Validation uses ordinary runs of Opus 5.5 at xhigh through the [Claude Code harness](0010-run-subscription-claude-through-claude-code-harness.md), two per case. A case stays only after two reviewed passes. If a case is at fault, it is fixed and that case alone gets two more Opus attempts; if the model simply missed, the case leaves the release and the reason is recorded. Validation runs are never published or scored: every surviving case passed both, so counting them would give Opus 100% by construction.

Once the current cases pass, about six more go through the same pipeline: Absinthe 1176 first, then new projects and feature or refactor tasks. No model's series runs before that release of about twenty cases is frozen. Opus 5.5, Sonnet 5.5 and Haiku 5.5 then each get a fresh [three-run series](0011-publish-three-run-series.md) at the highest effort Claude Code allows each of them, with Opus at xhigh. The results page states that Opus 5.5 validated the cases, which favours it slightly.

`admission.json` keeps the qualification hash it was admitted under as a historical record. Readiness at run time comes from the controller's automatic re-qualification under the grading code about to be used. A code change therefore never forces a case-file edit, which completes ADR 0011's rule that code changes never force a rerun.

## Considered options

- **Keep upstream pins under a recorded exception**: no fork work, but cases would keep two kinds of source and overlay handling.
- **Validate one parked case at a time**, as in the original curation loop: the same evidence with more folder shuffling, and none of it reusable for full-inventory runs.
- **Count the validation runs as Opus's first two series runs**: two fewer runs, but a score inflated by the selection itself.
- **Archive the old runs**: rejected because the records describe case versions that will no longer exist.
