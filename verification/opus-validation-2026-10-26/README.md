# Opus 5.5 validation, 2026-10-26

Unpublished validation runs under [ADR 0012](../../docs/adr/0012-rebuild-release-and-validate-with-unpublished-opus-runs.md): Opus 5.5 at xhigh effort through the [Claude Code harness](../../docs/adr/0010-run-subscription-claude-through-claude-code-harness.md) on the Claude subscription, with the validation flag set. None of these runs is scored or published.

## Runs

| Run | Scope | Outcome |
| --- | --- | --- |
| `20261026-160718-4102f1f8` | all 20 cases | Stopped after the transcript upload race (fixed in `78a375d8`). plausible-pr-5939 and plausible-pr-5956 had passed. It does not count toward validation: the harness kit changed before the next run, so its attempts do not share frozen inputs with later ones. |
| `20261026-162844-07bb9eac` | all 20 cases | Completed: **19 of 20 passed**. ash-pr-3031 failed. Per-case grade summaries and the sealed patches are in [`run-20261026-162844-07bb9eac/`](run-20261026-162844-07bb9eac/). |
| `20261026-224602-11868a92` | all 20 cases | Completed: **18 of 20 passed** as graded. accent-pr-183 failed only on a grader defect and passes when re-graded; ash-pr-3031 failed. Per-case grade summaries and the sealed patches are in [`run-20261026-224602-11868a92/`](run-20261026-224602-11868a92/). |
| `20261027-095752-a0aaa695` | all 20 cases, 2 parallel attempts | The first run under the parallel-attempts kit ([ADR 0014](../../docs/adr/0014-run-a-runs-attempts-in-parallel.md)). Completed: **18 of 20 passed**. livebook-pr-2800 and ash-pr-3031 failed. Per-case grade summaries, the sealed patches, the patches that show both failing cases are solvable, and the hook decision log are in [`run-20261027-095752-a0aaa695/`](run-20261027-095752-a0aaa695/). No elapsed times were recorded. |
| `20261027-143532-8d2e4ed2` | all 20 cases, 2 parallel attempts | Completed: **19 of 20 passed**. ash-pr-3031 failed. Per-case grade summaries, the sealed patches, the patches that show ash-pr-3031 is solvable, and the hook decision log are in [`run-20261027-143532-8d2e4ed2/`](run-20261027-143532-8d2e4ed2/). No elapsed times were recorded. |
| `20261027-183407-2bbea0a5` | all 20 cases, 2 parallel attempts | The first run under the session-level workspace server and the final case versions. Completed: **18 of 20 passed**. ash-pr-3031 and livebook-pr-2800 failed. Per-case grade summaries, the sealed patches, the patches that show both failing cases are solvable, and the hook decision log are in [`run-20261027-183407-2bbea0a5/`](run-20261027-183407-2bbea0a5/). No elapsed times were recorded. |

Raw transcripts stay in the controller's data volume: they carry the solver's environment block and account details.

## What the reviews of run 07bb9eac found

Every passing patch was reviewed against its ticket, requirements, reference and hidden tests, by independent reviewers who were given the bundles and run evidence. Every claim they made was checked against the files before anything changed.

- **All 19 passes are genuine.** No solution weakened or deleted an existing test. Every edit stayed inside the allowed prefixes, and no shortcut was found. The model's changes to existing tests (livebook-pr-2800 and absinthe-pr-1176) only add assertions, or apply output changes the ticket requires.
- **ash-pr-3031 failed on a stated requirement.** Opus converted a literal argument once, then let Ash convert it a second time inside a typed comparison. That breaks non-idempotent types (13 of 15 hidden checks pass). Adding the reference's two-line fix on top of the model's patch makes all 15 hidden checks pass. The case is sound. On 2026-10-26 **the user chose to keep it in the release** as an example that frontier models still miss stated behaviour; this is an exception to ADR 0012's drop rule. It gets its second Opus attempt in the next validation run.
- **16 cases had checks or texts that a wrong or partial solution could slip past, or a reference that failed its own requirement.** All were corrected; see [the case fixes](../case-fixes-2026-10-26/README.md). Four needed curator corrections to the reference: livebook-pr-2663, plausible-pr-6449, cachex-pr-341 and vutuv-pr-1759.
- **The grader's trusted formatter could lose a failure-phase, failure-type or excluded-tags record.** It printed those records without a leading newline, so ExUnit's progress dots could land before one and hide it from the parser. That could misjudge starting failures, a model's own tests, or a permitted exclusion. Fixed in `ada3d61c`. It was found when the revised livebook-pr-2663 failed qualification for exactly this reason.

## What the reviews of run 11868a92 found

The same method as for the first run: every passing patch was reviewed against its ticket, requirements, reference and hidden tests, and every finding was checked by running it before anything changed.

- **All 18 passes are genuine, and so is accent-pr-183's.** No solution weakened or deleted an existing test, special-cased hidden data or edited outside the allowed prefixes.
- **accent-pr-183 failed on a grader defect.** One of its six new test files ran a doctest on a module the starting source lacks, so the joint ExUnit run of its tests on the starting source never compiled and the coverage probe saw nothing. Its other files' tests catch the bug. The probe now runs each file on its own when the joint run does not complete (`lib/eab/grader.ex`). Re-graded under the fixed grader, the sealed patch passes every stage: [record](run-20261026-224602-11868a92/accent-pr-183/regrade-fixed-coverage-probe.json). All 20 cases re-qualified under the fixed grader.
- **ash-pr-3031 failed again, on two stated requirements.** Opus again let a normalized literal be converted twice inside a typed comparison beside an expression argument, and this time also crashed on an array argument given an expression (it unpacks the array before checking for an expression). 13 of 15 hidden checks pass. Probing showed the ticket also implied literal-only typed comparisons keep their values, which the reference does not do; the wording was narrowed.
- **15 cases had checks a plausible wrong solution still passes, texts that claim more than the reference delivers, or a reference that fails a stated input.** All were corrected; six needed curator corrections to the reference. See [the second case-fix batch](../case-fixes-2026-10-27/README.md).
- **Harness:** the activity logs no longer repeat the patch after every tool call, and no run left orphaned processes or hit the process limit.

Raw transcripts and activity logs stay in the controller's data volume.

## What the reviews of run a0aaa695 found

The same method as for the second run. This time every claimed gap was also run before anything changed: each wrong solution was built and shown to pass the released checks.

- **All 18 passes are genuine.** No solution weakened or deleted an existing test, special-cased hidden data or edited outside the allowed prefixes. Routing held with two attempts at once: each case was bound to one solver subagent, and every tool call came from that subagent.
- **livebook-pr-2800 failed on a stated requirement.** Opus built the message for an Erlang error with `:erlang.list_to_binary/1`, which raises on the non-ASCII text the ticket names, so 3 of 67 hidden checks fail. Opus's patch passes all of them with that one call replaced by `IO.chardata_to_string/1`, `List.to_string/1` or `:unicode.characters_to_binary/1` ([patches](run-20261027-095752-a0aaa695/livebook-pr-2800/soundness/)). The case is sound and the miss is the model's. On 2026-10-27 **the user chose to keep it**, like ash-pr-3031, as a case that measures model quality.
- **ash-pr-3031 failed again, on the same requirement as before.** Opus converted a normalized literal a second time inside a typed comparison beside an expression argument (13 of 15 hidden checks pass). Marking the already converted value, or wrapping it so it is not converted again, makes Opus's patch pass all 15 ([patches](run-20261027-095752-a0aaa695/ash-pr-3031/soundness/)).
- **9 cases had checks a plausible wrong solution still passes, a text that promises more than the reference does, or a reference that breaks a stated requirement.** All were corrected; two needed curator corrections to the reference. Opus's run-D patches for beacon-pr-687 and pinchflat-pr-610 fail the corrected checks. See [the third case-fix batch](../case-fixes-2026-10-27-run-d/README.md).

## What the reviews of run 8d2e4ed2 found

This was the final review before the release freezes. Each pass was read against its ticket, requirements, reference and hidden tests, and its activity log, grade and tool calls were read as well. Every claimed gap was run before anything changed.

- **All 19 passes are genuine.** No solution weakened or deleted an existing test, special-cased hidden data or edited outside the allowed prefixes. livebook-pr-2800 passed for the first time: Opus found the non-ASCII crash it missed in run a0aaa695.
- **ash-pr-3031 failed on the same two requirements as in run 11868a92.** Opus unpacked an array argument before checking for an expression, and converted a normalized literal a second time beside an expression argument (13 of 15 hidden checks pass). Opus's patch passes all 15 with both repaired ([patches](run-20261027-143532-8d2e4ed2/ash-pr-3031/soundness/)). The case is sound.
- **12 cases were accepted as they are.** 8 had a check a plausible wrong solution still passes, or a text that promised more than the reference does. They were corrected in [the final case-fix batch](../case-fixes-2026-10-27-run-e/README.md); no reference changed, and every run-E patch passes the corrected checks.
- **Harness: a parallel solver could lose a tool call's answer.** When one solver finished, Claude Code closed the workspace connection the other solver was still using: 4 calls in this run and 3 in run a0aaa695, each while the other solver finished. The solver saw the error and ran the command again; no grade changed, but a command could run twice. The kit now declares the workspace server once per session ([ADR 0014 amendment](../../docs/adr/0014-run-a-runs-attempts-in-parallel.md)).
- **Harness: the controller staged the solver's edits.** Its patch snapshot after each tool call ran `git add -A` in the solver's own index, so the solver's `git diff` showed nothing and `git checkout` restored nothing. In plausible-pr-6449 the solver "tested the starting source" with its fix still applied before noticing. The snapshot now stages into a copy of the index.
- **Environment: PostgreSQL ran out of memory in vutuv-pr-1759's full suite.** Every vutuv attempt since run 07bb9eac saw about 75 spurious failures in its own full-suite run when the kernel killed a PostgreSQL backend at the 512 MB limit. No graded command was affected. The database container now gets 1 GB, under which the full suite runs without a kill.

## What the reviews of run 2bbea0a5 found

Reviewed under the final-batch rule: each pass was checked for genuineness and for any fault of the case, and its logs were read.

- **All 18 passes are genuine, and no case is at fault.** No solution weakened or deleted an existing test, special-cased hidden data or edited outside the allowed prefixes. No review found a new check gap.
- **livebook-pr-2800 failed on a stated requirement.** This time Opus left the starting source's `:erlang.list_to_binary/1` call in place, which raises on the non-ASCII text the ticket names (3 of 67 hidden checks fail). With that one call replaced by `IO.chardata_to_string/1`, as the reference does, Opus's patch passes all 67 ([patch](run-20261027-183407-2bbea0a5/livebook-pr-2800/soundness/)).
- **ash-pr-3031 failed on the same two requirements as in runs 11868a92 and 8d2e4ed2** (13 of 15 hidden checks pass). Opus's patch passes all 15 with both repaired ([patches](run-20261027-183407-2bbea0a5/ash-pr-3031/soundness/)).
- **The harness fixes held.** No tool call lost its answer, including two long calls that were running while the other solver finished. The solvers' own `git diff` and `git checkout` worked on their edits, and vutuv-pr-1759's full suite ran without a database drop.

## Validation ledger

A case stays in the release after two reviewed passes under the same case version and harness kit (ADR 0012). A changed case starts its two attempts again. The kit changed after run 8d2e4ed2 ([ADR 0014 amendment](../../docs/adr/0014-run-a-runs-attempts-in-parallel.md)), so all 20 cases collect their two passes under the new kit; runs a0aaa695 and 8d2e4ed2 no longer count. Eight cases also changed in the final case-fix batch.

- **One reviewed pass under the current kit and case versions (run 2bbea0a5), one more needed:** absinthe-pr-1176, accent-pr-183, beacon-pr-687, cachex-pr-341, guardian-pr-748, livebeats-pr-37, livebook-pr-2219, livebook-pr-2527, livebook-pr-2663, livebook-pr-2822, livebook-pr-3076, operately-pr-1069, operately-pr-1205, pinchflat-pr-610, plausible-pr-5939, plausible-pr-5956, plausible-pr-6449 and vutuv-pr-1759.
- **Kept by the user's decision whatever their results:** ash-pr-3031 (Opus has missed stated requirements in all five attempts) and livebook-pr-2800 (missed in runs a0aaa695 and 2bbea0a5, passed in run 8d2e4ed2). Both stay sound cases Opus can be measured against.
- **Final batch:** on 2026-10-27 the user made the fixes after run 8d2e4ed2 the final strengthening batch. In the next two runs only a failure the case is at fault for changes a case; new minor gaps a review finds are recorded instead of reopening validation.
