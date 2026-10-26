# Prepared fork migration

Status: **completed on 2026-10-26** as part of the case rebuild ([ADR 0012](../../docs/adr/0012-rebuild-release-and-validate-with-unpublished-opus-runs.md)). The original audit and procedure below are kept as written.

## Rebuild record (2026-10-26)

- `prepare-case.py` published the 13 upstream-pinned cases to the user's forks: 17 new branches and 13 draft source-pair PRs, with no existing ref moved. Two changes were made to the reviewed utility: Ash's recorded single-run exception satisfies its completion prerequisite, and `--dry-run` reports the intended refs and PR before any push. Each case's `source-preparation.json` records the operations.
- The nine legacy cases were converted to schema v2 with every scored check stated as a requirement; the five newer cases kept their contracts. The freeze-audit fixes were applied in the same versions. Each case's `conversion-notes.md` holds the curator's mapping rationale and new incomplete controls where the legacy probe failed no starting failure (Livebook 2527, Plausible 5939).
- Independent reviewers approved every draft against its exact hashes (`source-review.json`), reading requirements before checks.
- `run-case.py qualify` then ran three fresh rounds per case under grader `da5bcd94…`. All fourteen passed with identical named outcomes and exported admissions. LiveBeats' three receipts are byte-identical because its Node output has no timestamps; its log shows three separate executions. Accent first failed to prepare when its Elixir 1.12 image ignored the Hex pin and installed Hex 2.6.0; it passed after the recipe installed Hex 2.5.3 directly.
- Opus validation follows once the Claude Code harness has passed its escape test.

Status before the rebuild: **read-only audit complete; migration deferred by the user**. Work remains on `codex/curate-researched-multifile-case`. The user authorized preparing and using their forks for every runnable case and specifically required inspecting existing Plausible branches before making changes.

The [Ash 3031 record](../case-curation-2026-10-20/ash-pr-3031/README.md) tracks the current new-case validation. The user subsequently requested finishing Ash and then stopping to limit token consumption. Do not execute these migration utilities without a renewed request. This directory contains read-only audits and independently reviewed procedures, not completed migration claims. No other fork or case source has been changed.

## What the audit established

All 13 pre-Ash manifests still point to upstream repositories. Their complete bundles and fork refs were recorded before any mutation in [initial-source-audit.json](initial-source-audit.json). Every original broken/fixed commit and tree exists in the supplied fork.

| Fork | Runnable cases | Existing preparation |
| --- | --- | --- |
| `Cinderella-Man/plausible-analytics` | 5939, 5956, 6449 | Three existing baseline branches match exactly; reuse them. |
| `Cinderella-Man/livebook` | 2219, 2527, 2663, 2800, 2822, 3076 | Six existing baseline branches match exactly; reuse them. |
| `Cinderella-Man/operately` | 1069, 1205 | Commit each existing neutral environment overlay on a new baseline branch. |
| `Cinderella-Man/live_beats` | 37 | Commit the existing browser/offline preparation on a new baseline branch. |
| `Cinderella-Man/accent` | 183 | Commit the existing native-build preparation on a new baseline branch. |

The Plausible fork has **six relevant existing baseline branches**. Three correspond to active cases; two belong to rejected cases 6441/6763 and one to retired case 6300. [The excluded-case audit](excluded-source-audit.json) verifies their source identities and historical bundles. Preserve all three excluded branches and their case status.

For each of the 13 current runtime images, an offline, read-only Git inspection confirmed that setup introduced no tracked-source differences beyond its recorded environment overlay. [runtime-tree-audit.json](runtime-tree-audit.json) retains the exact comparisons. All four overlays are disjoint from their upstream implementation/test changes; the complete prepared-pair binary diffs equal the original pairs.

## Procedure and evidence

Follow [prepared fork sources](../../docs/prepared-fork-sources.md) and the [curation workflow](../../docs/case-curation-loop.md). Every runnable case must use its recorded prepared branch in the user's fork. Keep runtime dependency/assets/database preparation and validated caches; move durable source edits into the baseline once.

`prepare-case.py` rescans every current branch, reuses compatible trees, and publishes only new refs with server-enforced absence checks. It preserves upstream authorship, verifies the exact source-pair diff, creates or reuses a draft fork source-pair PR, and writes an unadmitted draft. See [preparation-review.md](preparation-review.md).

`run-case.py` has explicit `qualify` and `validate` stages. It binds genuine independent review to draft hashes, checks controller activity and standalone leases, executes three fresh controls, rebuilds an admitted singleton, installs the disabled observer, and starts two ordinary fresh Astra runs. It stops on failure and leaves sealed-patch review and restoration to the curator. [workflow-review.json](workflow-review.json) records both independent review axes and resolved findings.

The `.exs` utilities are copied into the controller together with `validation-measurement.ex`. Their job manifest records script hashes. `evidence-binding.exs` connects all three qualification receipts, current runtime and verified source tree to each solver's saved artifacts. Cases with legacy contracts retain their format and semantics. Source migrations receive new evidence; historical attempts remain attached to their original releases.

Working drafts, logs and no-checkout fork clones live under ignored `.local/fork-migration/`. To reproduce a stage, copy the retained scripts into that working directory, inspect the current controller/private receipts and existing job paths first, and supply the committed Ash-completion prerequisite. Destination collisions stop for inspection; rerunning a whole stage is not a retry policy.

Each completed case will have its own source preparation/review, three qualification summaries, two sealed patches/results, independent model review and bundle hashes below this directory. Final restoration must verify every original ref, excluded bundle, prepared baseline/reference branch, applicable admission, normal observer and full release. These functional validations provide no speed evidence and no combined full-inventory model score.
