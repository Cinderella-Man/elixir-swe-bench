# Case fixes after the first Opus validation run, 2026-10-26

The reviews of [Opus validation run `20261026-162844-07bb9eac`](../opus-validation-2026-10-26/README.md) showed that 16 of the 20 cases had a gap: a plausible wrong or partial solution passed every check, a requirement text claimed more than the checks or the reference, or the reference itself failed a requirement its ticket states. The user asked for every task, reference and checker to be right ("we are creating the golden dataset"), so each of these cases was corrected.

## How each change was proven

Each change was first exercised in throwaway containers built from the case's prepared runtime image, with the prepared database images beside it, mirroring the grader's hidden stage. Each case was run against:

- the reference;
- Opus's patch from the validation run;
- the untouched starting source;
- the case's partial-fix control;
- one or more **wrong solutions** the new checks target, run against both the old and the new checks.

A check counts as closing a gap only if its wrong solution passed the old checks and fails the new ones, while the reference and Opus's patch pass. The wrong-solution patches are kept per case under `wrong-fixes/`; for a case whose reference was corrected, the previous reference plays that role.

To repeat a check, use [`tools/hidden-check.sh`](tools/hidden-check.sh). It applies a solution in a throwaway container, restores `test/`, applies the hidden tests and runs the acceptance command. Set `EAB_RUNTIME_DIR` to a folder of `runtime-<case>.json` records, copied from the controller's `/data/runtimes`, and `EAB_DRAFTS_DIR` to a folder of case bundles. For example:

```sh
tools/hidden-check.sh livebook-pr-2800 whole-cell livebook-pr-2800/wrong-fixes/whole-cell.patch ../../cases/livebook-pr-2800/acceptance.patch
```

[`tools/newfile_patch.py`](tools/newfile_patch.py) extracts or replaces one new file inside a patch, which is how the hidden test files were edited.

Independent reviewers then approved every changed bundle against its exact file hashes. They were given the bundles and the starting source, not the curator's notes; each case's `independent-review.json` holds its review. Finally each case passed three fresh qualification rounds with identical named outcomes under the final grader (`qualification-round-{1,2,3}.json`, `prepared-source-tree.json`).

## Changes

| Case | Change | Wrong solutions now rejected |
| --- | --- | --- |
| accent-pr-183 | Version selection independent of creation order; in-place translation (JIPT) export and sync/merge previews checked; ticket and requirement name those routes | skipping the in-place export (passed 6/6 old checks) |
| livebook-pr-2219 | The frame test waits for the edited value to reach the session before appending, which removes a race that could fail the reference too; the partial-fix control is now a realistic data-side-only fix | — |
| livebook-pr-2527 | A markdown paragraph and a new section inserted before the stamp; exactly one warning | rejecting only code fences, or only code cells (47/47 old) |
| livebook-pr-2663 | **Reference corrected**: tight lists with items numbered 10 or higher keep their blocks on consecutive lines, as a code block followed by a sub-list otherwise turned the whole list loose. Two new checks; requirement wording scoped to the item shapes the reference handles, with numbering out of scope | the upstream-only fix fails the two new checks |
| livebook-pr-2800 | Errors after real code on line 1: only the offending line may appear | showing the whole cell, or its first non-blank line (60/60 old) |
| livebook-pr-3076 | The invalid form is submitted, and nothing may be saved for this test's bucket | saving without validating the form (13/13 old) |
| plausible-pr-6449 | **Reference corrected**: segment ids beyond the PostgreSQL bigint range name no segment, where the upstream lookup crashed. Partly numeric and out-of-range selections are checked; all 31 hidden tests are mapped to requirements | lenient number parsing (30/30 old) |
| operately-pr-1069 | An author who mentions themselves; one person mentioned in two id forms | adding the author separately and filtering mentions only against the selected people (4/4 old) |
| operately-pr-1205 | Wording only: scoped to fetching a single project | — |
| livebeats-pr-37 | Tab title and metadata through the player's Next and Previous controls; restore wording scoped to the profile's song list page | setting the title only on a row click (3/3 old) |
| pinchflat-pr-610 | No-longer-pending and user-script-veto skips keep the reason; the Failed tab pages newest-first, ten per page | a static Failed list, and recording a reason on a script veto (15/15 old each) |
| beacon-pr-687 | The sitemap index route is also declared in an aliased scope; 105 pages | the curator's earlier plain-route alternative, and a 100-page cap (8/8 old each) |
| guardian-pr-748 | VerifyCookie resolves once; wrong arity raises on every entry point; exceptions from a `:secret` function propagate | turning a failed secret lookup into an authentication error (16/16 old) |
| cachex-pr-341 | **Reference corrected**: unnamed warmers are looked up again under the Incubator for warming and provisions, so a restarted warmer stays reachable. Checks added for: restart; no wait timeout; hook notifications; an unnamed module that is another warmer's name; `only:` over `modules:` | the previous reference fails the restart check |
| absinthe-pr-1176 | The five existing test files the regression stage omitted now run in the hidden stage, with only the five intended assertions updated. A field-placement message is loosened so it does not pin the reference's internal placement name. Subscription roots, the `__Schema` description and multi-line descriptions are checked; all 113 hidden tests are mapped | allowing a top-level `field`, and deleting the `__Schema` description (11/11 old each) |
| vutuv-pr-1759 | **Reference corrected**: the handle check confirms handles with the renderer, which resolves a contradiction in the ticket. A held-for-review avatar is no picture. Six new checks; six existing files added to the regression stage | applying the 50-handle cap before removing duplicates, and returning the medium avatar instead of the thumbnail (14/14 old each) |

The four reference corrections are curator commits on the forks' reference branches, recorded in each case's `provenance.json`:

- [livebook](https://github.com/Cinderella-Man/livebook/pull/3): `2a3a6ae6`
- [plausible-analytics](https://github.com/Cinderella-Man/plausible-analytics/pull/3): `23339133`
- [cachex](https://github.com/Cinderella-Man/cachex/pull/1): `f0ebf5fb`
- [vutuv](https://github.com/Cinderella-Man/vutuv/pull/1): `d56dde42` and `88ec5568`

Each reconstructs its recorded fixed tree from the baseline plus the bundle's patches. [ADR 0013](../../docs/adr/0013-specify-feature-cases-with-grilled-specs.md) now covers corrections to bug-fix references.

## A grader fix found on the way

Qualifying the revised livebook-pr-2663 failed because a test's failure-phase record had two progress dots in front of it, so the grader never read the phase. The trusted formatter printed `EAB_TEST` records after a newline, but its failure-type, failure-phase and excluded-tag records directly. Every record now starts on its own line (`ada3d61c`, with a test that inserts dots between the formatter's writes). The same race could have dropped a permitted exclusion or a model test's failure phase. All cases were qualified again under the fixed grader.

## Left as they are

- **accent-pr-183:** whether a pre-release tag is "compatible" is not specified and not checked.
- **plausible-pr-5956:** only the HTTP behaviour is checked; that matches its spec.
- **Cosmetic notes from review:** stale `index` lines in some patch headers, which `git apply` ignores, and unformatted new test code in operately-pr-1069 and guardian-pr-748.

## Status

- **Qualification:** all 16 changed cases passed three fresh qualification rounds with identical named outcomes under grader `223a3ab5…`. In every round the reference passes and the starting source, the partial fix and the early exit all fail.
- **Release:** the restored release has 20 cases. The controller's inventory matches the checkout and every admission verifies. The four cases this batch did not touch are byte-identical to before.
- **Forks:** every case's fork branches point at the commits its provenance records.
- **Validation:** the 16 changed cases need two new Opus validation attempts on their new versions, and the four unchanged cases one more each (see the [validation record](../opus-validation-2026-10-26/README.md)).
