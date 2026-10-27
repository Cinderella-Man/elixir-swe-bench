# Rebuild the release on prepared forks and validate it with unpublished Opus runs

Before any scored run, the fourteen cases are rebuilt so that every case works the same way. Each case gets a prepared baseline branch, a reference branch and a source-pair PR in the user's fork, with every environment change inside the fork instead of an `environment.patch` overlay. Images are pinned by digest. Each case uses the schema-v2 contract, with every scored check stated as a solver-visible requirement, plus an admission receipt, an independent review and three matching qualification rounds. The [freeze audit](../verification/case-freeze-audit-2026-10-26.md) fixes go into the same versions. All earlier runs, releases, qualification records and published results were deleted without an archive on 2026-10-26, because they belong to case versions that are being replaced. Preparation caches and the ChatGPT sign-in were kept.

Validation uses ordinary runs of Opus 5.5 at xhigh through the [Claude Code harness](0010-run-subscription-claude-through-claude-code-harness.md), two per case. A case stays only after two reviewed passes. If a case is at fault, it is fixed and that case alone gets two more Opus attempts; if the model simply missed, the case leaves the release and the reason is recorded. Validation runs are never published or scored: every surviving case passed both, so counting them would give Opus 100% by construction.

Once the current cases pass, about six more go through the same pipeline: Absinthe 1176 first, then new projects and feature or refactor tasks. No model's series runs before that release of about twenty cases is frozen. Opus 5.5, Sonnet 5.5 and Haiku 5.5 then each get a fresh [three-run series](0011-publish-three-run-series.md) at the highest effort Claude Code allows each of them, with Opus at xhigh. The results page states that Opus 5.5 validated the cases, which favours it slightly.

`admission.json` keeps the qualification hash it was admitted under as a historical record. Readiness at run time comes from the controller's automatic re-qualification under the grading code about to be used. A code change therefore never forces a case-file edit, which completes ADR 0011's rule that code changes never force a rerun.

## Amendment, 2026-10-26: what the first validation run changed

The first complete validation run passed 19 of 20 cases. Its reviews found something a pass alone does not show: in 16 cases, a wrong or partial solution could also have passed, or the reference itself failed a stated requirement. Those cases were corrected with stronger checks, exact requirement texts and, for four of them, curator corrections to the reference. Every correction was proven against the reference, the model's patch, the starting source and the wrong solutions it targets, then independently reviewed and qualified. A changed case starts its two validation attempts again. Reviewing a pass therefore includes trying the wrong solutions the checks should reject, not only reading the patch. See the [validation record](../../verification/opus-validation-2026-10-26/README.md).

The user kept ash-pr-3031 although Opus missed one of its stated requirements: the case is sound, the reference's fix is two lines, and it shows that frontier models still miss stated behaviour. This is an explicit exception to the drop rule above. The case keeps its validation attempts, so a later pass is still recorded.

## Amendment, 2026-10-27: what the second validation run changed

The second complete run passed 18 of 20 as graded. accent-pr-183's only failure came from the grader: one of the model's test files could not compile on the starting source and hid its other files from the coverage probe, which now runs each file on its own in that case. Re-graded, the patch passes. Reviewing the passes found a further 15 cases with checks a plausible wrong solution still passes, texts that claim more than the reference delivers, or references that fail a stated input; six references got curator corrections. These were corrected the same way and start their two attempts again, so this amendment keeps the rule rather than relaxing it. Two of the second run's passes (vutuv-pr-1759 and guardian-pr-748) would fail the corrected checks, which is why a pass is reviewed rather than trusted. See the [validation record](../../verification/opus-validation-2026-10-26/README.md).

## Amendment, 2026-10-27: what the third validation run changed

The third complete run, the first with two parallel attempts under [ADR 0014](0014-run-a-runs-attempts-in-parallel.md), passed 18 of 20. Its reviews found 9 more cases where a wrong solution the reviewers built passes every check, a text promises more than the reference, or a reference breaks a stated requirement (two got curator corrections). Each gap was run before anything changed, and the cases were corrected the same way. livebook-pr-2800 failed because Opus built an error message in a way that raises on the non-ASCII text the ticket names; replacing that one call makes its patch pass. The user kept it on the same terms as ash-pr-3031: a sound case that measures model quality, not a case at fault. See the [validation record](../../verification/opus-validation-2026-10-26/README.md).

## Amendment, 2026-10-27: the fourth validation run and the final batch

The fourth complete run passed 19 of 20; ash-pr-3031 failed on the same requirements as before and stays on the user's terms. Its reviews accepted 12 cases as they are. 8 got one more check or a narrower text, each backed by a wrong solution that passed the released checks; no reference changed. Two harness faults and one environment fault turned up in the logs and were fixed with them. The user made this the final strengthening batch: in the two runs that follow, a case changes only for a failure the case is at fault for, and new minor gaps a review finds are recorded rather than reopening validation. Without that stop, each review of a pass keeps finding smaller gaps (16, 15, 9 and 8 cases in four batches), and validation would never end. See the [validation record](../../verification/opus-validation-2026-10-26/README.md).

## Considered options

- **Keep upstream pins under a recorded exception**: no fork work, but cases would keep two kinds of source and overlay handling.
- **Validate one parked case at a time**, as in the original curation loop: the same evidence with more folder shuffling, and none of it reusable for full-inventory runs.
- **Count the validation runs as Opus's first two series runs**: two fewer runs, but a score inflated by the selection itself.
- **Archive the old runs**: rejected because the records describe case versions that will no longer exist.
