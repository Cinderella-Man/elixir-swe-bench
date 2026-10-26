# Rebuild the release on prepared forks and validate it with unpublished Opus runs

Before any scored run, the fourteen cases are rebuilt so that every case works the same way. Each case gets a prepared baseline branch, a reference branch and a source-pair PR in the user's fork, with every environment change inside the fork instead of an `environment.patch` overlay. Images are pinned by digest. Each case uses the schema-v2 contract, with every scored check stated as a solver-visible requirement, plus an admission receipt, an independent review and three matching qualification rounds. The [freeze audit](../verification/case-freeze-audit-2026-10-26.md) fixes go into the same versions. All earlier runs, releases, qualification records and published results were deleted without an archive on 2026-10-26, because they belong to case versions that are being replaced. Preparation caches and the ChatGPT sign-in were kept.

Validation uses ordinary runs of Opus 5.5 at xhigh through the [Claude Code harness](0010-run-subscription-claude-through-claude-code-harness.md), two per case. A case stays only after two reviewed passes. If a case is at fault, it is fixed and that case alone gets two more Opus attempts; if the model simply missed, the case leaves the release and the reason is recorded. Validation runs are never published or scored: every surviving case passed both, so counting them would give Opus 100% by construction.

Once the current cases pass, about six more go through the same pipeline: Absinthe 1176 first, then new projects and feature or refactor tasks. No model's series runs before that release of about twenty cases is frozen. Opus 5.5, Sonnet 5.5 and Haiku 5.5 then each get a fresh [three-run series](0011-publish-three-run-series.md) at the highest effort Claude Code allows each of them, with Opus at xhigh. The results page states that Opus 5.5 validated the cases, which favours it slightly.

`admission.json` keeps the qualification hash it was admitted under as a historical record. Readiness at run time comes from the controller's automatic re-qualification under the grading code about to be used. A code change therefore never forces a case-file edit, which completes ADR 0011's rule that code changes never force a rerun.

## Amendment, 2026-10-26: what the first validation run changed

The first complete validation run passed 19 of 20 cases. Its reviews found something a pass alone does not show: in 16 cases, a wrong or partial solution could also have passed, or the reference itself failed a stated requirement. Those cases were corrected with stronger checks, exact requirement texts and, for four of them, curator corrections to the reference. Every correction was proven against the reference, the model's patch, the starting source and the wrong solutions it targets, then independently reviewed and qualified. A changed case starts its two validation attempts again. Reviewing a pass therefore includes trying the wrong solutions the checks should reject, not only reading the patch. See the [validation record](../../verification/opus-validation-2026-10-26/README.md).

The user kept ash-pr-3031 although Opus missed one of its stated requirements: the case is sound, the reference's fix is two lines, and it shows that frontier models still miss stated behaviour. This is an explicit exception to the drop rule above. The case keeps its validation attempts, so a later pass is still recorded.

## Considered options

- **Keep upstream pins under a recorded exception**: no fork work, but cases would keep two kinds of source and overlay handling.
- **Validate one parked case at a time**, as in the original curation loop: the same evidence with more folder shuffling, and none of it reusable for full-inventory runs.
- **Count the validation runs as Opus's first two series runs**: two fewer runs, but a score inflated by the selection itself.
- **Archive the old runs**: rejected because the records describe case versions that will no longer exist.
