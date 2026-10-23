# Prepared fork sources

Every runnable case must pin a prepared baseline branch in the user's fork. Follow this procedure when adding a case, resuming a draft, or changing an existing case's repository, preparation or source revision. The [curation workflow](case-curation-loop.md) supplies isolation, review, qualification, solver validation and restoration.

## Inspect before preparing

Record the complete current case bundle, upstream source pair, environment overlay and runtime setup commands. Inspect the supplied fork's parent, default branch and **all existing branches** before creating refs. Compare commits, trees, ancestry and preparation changes; an upstream URL in `case.json` does not mean the fork lacks a suitable branch.

Reuse a compatible branch whose tree is exactly the intended prepared baseline. Preserve default, unrelated, rejected and retired case branches. When a new branch is needed, use a case-specific `codex/` name, check collisions immediately before publication, and enforce absence on the server. For example, an atomic push with `--force-with-lease=refs/heads/<new-name>:` is a create-only check when the expected value is empty; never supply an existing ref to that operation. Verify all previously recorded refs remain unchanged afterward.

**Ready:** the fork is the expected project, existing branch matches are accounted for, and the exact baseline/reference trees and intended new refs are recorded.

## Put durable preparation in the fork

The baseline contains the historical broken application plus only the preparation needed to build and exercise it reproducibly: toolchain declarations, offline test setup, native dependency build helpers or neutral reporting support. Review each preparation change independently of the repair. Keep the defect intact.

Commit this preparation once in the fork. Apply the same preparation to the reference side, preserving the original accepted repair, exact upstream tests, documentation, author and notices. Compare the complete original and prepared source-pair diffs. Hidden acceptance checks and incomplete/integrity controls stay in the benchmark bundle.

Create a real draft PR between these two fork branches for source provenance. It records the prepared source pair; keep it unmerged so the baseline remains broken. Store the original upstream repository, PR, revisions and trees separately under `provenance.upstream`. Current provenance must identify the actual fork:

- `case.json.repository`: fork URL and immutable baseline commit.
- `provenance.json`: that same fork, its source-pair PR, baseline/reference commits and trees, `preparation_branch` and `reference_branch`.
- `provenance.preparation`: original preparation inputs and paths, including the old environment-patch hash where applicable.

Verify both remote branches still resolve to the recorded commits. Reconstruct the fixed tree from the prepared baseline with `reference.patch`, exact upstream tests and retained documentation. The branch name is a maintenance reference; execution remains pinned to the commit and tree.

Once preparation is committed, remove the corresponding `environment.patch` from the new bundle. Keep required dependency downloads, compilation, asset builds and database/service initialization in runtime preparation. A prepared source branch does not contain compiled dependencies or replace validated image/database caches.

**Ready:** cloning the pinned baseline needs no source rewrite; the exact prepared reference reconstructs; preparation is neutral; and upstream authorship remains traceable.

## Verify the executable source and evidence

Build or reuse the exact prepared runtime, then inspect its committed workspace tree with a bounded, offline, read-only Git command. Compare it with the pinned baseline tree. Setup commands must not introduce unrecorded tracked-source differences. Retain the image identity, tree and comparison result.

Review the new immutable bundle against the visible contract. Existing source migrations preserve tickets, grading semantics, reference/check patches and legacy contract format unless a separately diagnosed correction requires changing them. Export fresh schema-v2 admission evidence where applicable.

Complete three fresh control rounds and two fresh ordinary Opus runs under the [curation policy](case-curation-loop.md). Historical successes and diagnostic replays stay tied to their original releases. They are not fresh blind runs of a changed version.

Any explicit change to the required run count follows the workflow's [user-override policy](case-curation-loop.md#validation-scope-and-user-overrides). Reusable branches, a migrated source manifest and completed validation are separate audit states; see [source-screening lessons](curation-lessons.md#screen-the-exact-source-before-preparing-it).

Bind all three checksummed receipts to the currently ensured runtime and qualification identity. Compare complete named outcomes, completion, failure phases/types and both model-test probes. Before each model launch, verify that identity and the source-tree-verified image. Afterward, require each run's saved `qualification.json` and `runtime.json` to match those receipts; agreement between the two runs alone is insufficient if the runtime changed after qualification.

Review both sealed submissions, retain every attempt, and restore all approved cases with the normal controller observer. Verify every active fork URL, remote baseline/reference identity, source reconstruction, applicable admission and full restored release before committing the completed migration.

**Done:** every active case uses its recorded prepared fork baseline, all gates belong to that exact version, excluded branches remain unchanged, and the full inventory is restored.
