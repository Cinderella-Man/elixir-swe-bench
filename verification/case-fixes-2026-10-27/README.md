# Case fixes after the second Opus validation run, 2026-10-27

Reviews of [Opus validation run `20261026-224602-11868a92`](../opus-validation-2026-10-26/README.md) (run C) read each passing patch against its ticket, requirements, reference and hidden tests. They found no shortcut or weakened test, but they did find checks a plausible wrong solution still slips past, texts that claim more than the reference delivers, and references that fail a stated input. The same standard as [the first batch](../case-fixes-2026-10-26/README.md) applies: every task, reference and check must be right.

## How each change was proven

The method is the first batch's. Each change ran in throwaway containers built from the case's prepared image, mirroring the grader's hidden stage, against:

- the reference;
- Opus's patch from run C;
- the untouched starting source, which must fail exactly the listed starting failures in test bodies;
- the case's partial-fix control, which must still fail;
- one or more **wrong solutions** the change targets. Each passed the old checks and fails the new ones. They are kept per case under `wrong-fixes/`; for a corrected reference, the previous reference is one of them.

Checks involving processes, browsers or shared state ran at least three times on the reference. Independent reviewers then approved every changed bundle against its exact file hashes (`independent-review.json`). Two reviewers first rejected a draft whose texts still overclaimed (livebook-pr-2822 and guardian-pr-748); both drafts were corrected and approved on re-review. Finally each case passed three fresh qualification rounds with identical named outcomes under grader `ba6b3fe3…` (`qualification-round-{1,2,3}.json`, `prepared-source-tree.json`).

## A grader fix found on the way

accent-pr-183 failed run C only on regression coverage. Its patch was correct, and its own tests catch the bug, but one of its six new test files ran a doctest on a module the starting source lacks. That file stopped the whole ExUnit run from compiling, so the probe saw no test at all. The probe now runs each added test file on its own when the joint run does not complete: a file that cannot compile on the starting source counts for nothing and no longer hides the others (`lib/eab/grader.ex`, with a unit test). Re-graded under the fixed grader, the same sealed patch passes every stage ([record](../opus-validation-2026-10-26/run-20261026-224602-11868a92/accent-pr-183/regrade-fixed-coverage-probe.json)). The change only adds detections when the joint run fails, so no earlier pass changes. All 20 released cases re-qualified under the fixed grader before this batch.

## Changes

| Case | Change | Wrong solutions now rejected |
| --- | --- | --- |
| accent-pr-183 | The in-place translation (JIPT) export and both previews are checked for literal-tag precedence; unmatched, invalid and omitted versions are checked on every route | resolving the requirement before the literal tag on JIPT or on the previews; treating an invalid requirement as unversioned; serving the highest version when the version is omitted (each 9/9 on the old checks) |
| ash-pr-3031 | Wording only: normalized literals keep their values in typed comparisons when the calculation also receives an expression argument, which is what the reference delivers; the literal-only case is unchanged upstream behaviour | — |
| plausible-pr-6449 | **Reference corrected**: a list- or map-shaped segment selection names no segment (the reference crashed on a map and stored a list). Checks for a segment of another site in the same team, a foreign segment already on the link, and list/map selections | team-scoped lookup, keeping a resubmitted id unchecked (31/31 old each) |
| livebeats-pr-37 | A second browser listens to the owner's profile and follows the owner's song changes, including after it navigates away; wording scoped to when a song starts or changes | a title set only by this browser's own handlers; a title set only on the owner's profile page (4/4 old each) |
| livebook-pr-2527 | A team-hub notebook with added content gets that hub's invalid-stamp message | always the personal-hub message (49/49 old) |
| livebook-pr-2800 | **Reference corrected**: Erlang errors that quote non-ASCII characters are reported as SyntaxErrors (the reference raised while building the message). Error on a middle line of the cell | showing the rest of the cell or its last line (63/63 old); Latin-1-only and parser-only Unicode handling |
| livebook-pr-2822 | Wording only: rollback covers the failed cell's context, process-dictionary entries and its `defmodule` modules; the random seed and the evaluator's own keys are shared; an evaluator initialized from another is excluded | — |
| livebook-pr-3076 | The S3 validation test uses its own bucket and runs synchronously, removing two flakes (a reused port matching a leftover stored file system, and a parallel test resetting the hub form) | — |
| operately-pr-1069 | A mention in full-UUID form, and a selected recipient in mixed id forms | de-duplicating raw ids before decoding (6/6 old each) |
| guardian-pr-748 | A custom `secret_fetcher` receives a nil connection secret and decides the outcome; wording on when a wrong-arity function raises, what a custom fetcher receives, and `:refresh_from_cookie` taking over failed header and session checks | failing closed before the fetcher (Opus's run-C patch, 21/21 old) |
| vutuv-pr-1759 | **Reference corrected**: handles order the same way before and after the limit, and a NUL byte in a term matches nothing instead of a 500. The ordering is pinned as lowercased character-by-character comparison; checks for that order, limit prefixes, NUL bytes and more handle shapes Markdown keeps whole | dropping handles ending in `_`, or with two `_` (20/20 old each); the previous reference |
| cachex-pr-341 | **Reference corrected**: startup selects each warmer group exactly, so a warmer named after another warmer's module runs once in its own mode. The restart check now verifies the restarted warmer's write | the previous reference; grouping by `only:` in one direction; a restarted warmer that stores nothing (15/15 old each) |
| absinthe-pr-1176 | Several `extend schema` blocks accumulate and keep the declaration's description; the declaration comparison no longer hides duplicated entries; scope states that custom query root names and other schema providers are not covered | dropping the description on extension; last extension wins; entries rendered twice (113/113 old each) |
| beacon-pr-687 | **Reference corrected**: control characters in a page path are percent-encoded, so the sitemap stays well-formed. A router calling `beacon_sitemap_index` unqualified after `use Beacon.Router` | leaving the macro out of the import (8/8 old); the previous reference |
| pinchflat-pr-610 | **Reference corrected**: a download whose details cannot be saved records a reason, on the main and the SponsorBlock recovery path, with retries unchanged; a reason for unexpected exceptions is stated as unspecified | the previous reference; fixing the main path only (17/17 old) |

Opus's run-C patches fail two of the new checks: vutuv-pr-1759 (it ordered with the database's locale, which the pinned text now rules out) and guardian-pr-748 (it failed closed before a custom fetcher, against the ticket's compatibility rule). Both cases restart validation anyway. Every other run-C and run-B patch still passes its case.

The reference corrections are curator commits on the forks' reference branches, recorded in each case's `provenance.json`:

- [plausible-analytics](https://github.com/Cinderella-Man/plausible-analytics/pull/3): `3f089282`
- [livebook](https://github.com/Cinderella-Man/livebook/pull/4): `ba47c7a9`
- [vutuv](https://github.com/Cinderella-Man/vutuv/pull/1): `a3edb9dc`
- [cachex](https://github.com/Cinderella-Man/cachex/pull/1): `3d318f7f`
- [beacon](https://github.com/Cinderella-Man/beacon/pull/1): `5c38d34e`
- [pinchflat](https://github.com/Cinderella-Man/pinchflat/pull/1): `b9380388`

Each reconstructs its recorded fixed tree from the baseline plus the bundle's patches.

## Left as they are

- **plausible-pr-5956:** a hidden helper writes `Tracker.build_script/1` output straight into the script cache, so a correct fix that renames those helpers or changes what the cache stores would fail. No solution so far has done so; the case has two reviewed passes.
- **livebook-pr-3076:** the exact upstream test "personal creates a S3 file system" could in principle meet the same port-reuse collision within one test run. Each grading stage starts from a fresh container.
- **Cosmetic:** stale wording in some `pair_selection` notes, one 101-column line in a vutuv hidden test.

## Status

- **Qualification:** all 15 changed cases passed three fresh qualification rounds with identical named outcomes under grader `ba6b3fe3…`. In every round the reference passes and the starting source, the partial fix and the early exit all fail.
- **Release:** the restored release has 20 cases. The controller's inventory matches the checkout and every admission verifies. The five cases this batch did not touch are byte-identical to before.
- **Forks:** every case's preparation and reference branches point at the commits its provenance records.
- **Controller tests:** the full suite passes (235 tests), as does the Docker-backed grading test.
- **Validation:** the 15 changed cases need two new Opus validation attempts on their new versions; see the [validation record](../opus-validation-2026-10-26/README.md).
