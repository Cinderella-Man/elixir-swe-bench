# Sequential case curation

Use this workflow when asked to add cases, finish a candidate, or change an existing case's source or preparation. Work on one candidate at a time, validate it, park it, then continue only within the requested scope. Finish a batch with all approved cases restored so the merge contains the changes and their evidence.

**“Run against Opus” means run the actual benchmark with Opus 5.5 at extra-high effort (`claude-opus-5-5`, `xhigh`) as the solver through the [Claude Code harness](adr/0010-run-subscription-claude-through-claude-code-harness.md).** It is the only validator for new cases; curation sessions also run on Opus 5.5. Fixture qualification without a model, a curator-written solution, and a subagent the curator briefs by hand are not those solver runs. Earlier Astra validations through the Pi runner keep their evidence, but Astra runs no longer validate new cases. The harness is not implemented yet; until it is, new-case validation cannot run.

Before selecting a researched candidate or freezing its checks, use [curation diagnostics and lessons](curation-lessons.md) to check source-pair drift and preservation risks. Return to that guide for reporter discrepancies, runtime/evidence mismatches or surprising solver results.

## Folder roles

| Location | Purpose |
| --- | --- |
| `cases/` | Active inventory. During a solver run, contains exactly the candidate being validated. At batch completion, contains the full approved inventory. |
| `cases_approved/` | Temporary holding folder for validated cases, excluded from runs. Move complete case directories here unchanged, including admission receipts. |
| Draft directory outside both folders | Unqualified or deferred candidate bundles; not part of the validated inventory. |
| `verification/case-curation-<date>/<case-id>/` | Qualification outcomes, model attempts, patches, reviews and continuation notes. |

Folder membership determines the active set. `config/benchmark.json` supplies defaults and preferred ordering; new case folders are discovered automatically. No case ID, manifest or configuration edit is needed merely to park or restore a case. Leave folder-level files such as `cases/README.md` and `.gitkeep` in place.

## 1. Establish the branch and recover existing work

Read the worktree status, current case folders and any candidate's verification record before changing them. For a new curation branch, fetch main and branch from the current `origin/main` using the `codex/` prefix. When continuing an existing curation branch, use its recorded state rather than restarting completed work.

For an unfinished case from an older branch, inspect its diff first. Import only that candidate's bundle, contract review and case-specific evidence onto the new branch. Main may have moved substantially: keep current harness/configuration code and existing cases. Verify imported admission and qualification evidence against current source, artifact hashes, grader and runtime identities.

Record the original approved case IDs and file hashes before moving them. These establish that restoration preserves every original bundle except explicitly authorized migrations. For a migration, retain the old bundle and record the approved replacement's complete hashes separately.

Record the current authorized candidate count, required solver-run count and stopping condition. Resolve source/preparation and cheap diagnostic uncertainties before scheduling repeated controls or model runs. Reuse applicable reviewed utilities after checking their pinned versions and destinations; a curation task does not require building a new orchestration system.

**Ready:** the branch/base and candidate are identified, existing work is preserved, and any reused evidence has been checked rather than assumed valid.

## 2. Park approved cases and isolate the candidate

Check the running controller's `Eab.Runs.snapshot()`: `active` must be `nil`, `cleaning` must be `false`, and `cleanup_error` must be `nil`. Also finish any standalone qualification/preparation using its data volume. Wait for active work; do not interrupt another run to change folders.

Create `cases_approved/` if needed. Move every already-approved directory containing `case.json` from `cases/` into it. Check destination names first and stop on a collision instead of merging or overwriting directories. On a resumed branch, keep the single unfinished candidate separate from approved cases and investigate any other active folders.

Docker copies case files into the controller image; host moves alone do not change its inventory. After membership changes, rebuild/recreate the idle controller with `docker compose up --build -d`. Inspect `Eab.Inventory.all()` inside that controller before launching a model. It must equal `[candidate_id]`; a host directory listing is insufficient.

**Ready for model validation:** only the qualified candidate is active in both the checkout and controller; all other approved cases are parked.

## 3. Prepare and qualify the fixture

Every runnable case must pin a prepared baseline branch in the user's fork. Follow [prepared fork sources](prepared-fork-sources.md) before creating refs or editing a source manifest: inspect every existing branch, reuse exact compatible preparation, preserve unrelated/excluded branches, and verify the prepared reference pair. Durable source preparation belongs in that branch; ordinary clones should not need an environment patch. Record and verify the exact prepared image's source tree after setup.

Follow the [selection guidelines](pr-selection-guidelines.md) and [admission APIs](case-admission.md) for source provenance, the minimal solver contract, independent requirements-first review, acceptance/preservation checks, and plausible incomplete/integrity controls.

Develop drafts outside `cases/`. For new cases and existing schema-v2 cases, import and review the immutable version through `Eab.Candidates`. For an existing legacy case's source migration, preserve its schema and grading semantics, hash the complete draft, retain genuine independent review against those hashes, and use the existing source/fixture/grader APIs under `Inventory.with_case/3`. Save checksummed source/runtime/grader receipts for that immutable version alongside its review; do not fabricate an admission receipt for a legacy bundle.

Complete **three fresh qualification rounds with matching named outcomes**, including completion and failure phases/types, through the applicable path. Each round executes reference, unchanged, incomplete and integrity controls in fresh workspaces/service state. A cached qualification lookup is not another fresh round; preserve the previous receipt outside the cache lookup before repeating controls. Prepared images may be reused.

Inspect the first round's complete named outcomes before scheduling the remaining rounds. Resolve incorrect starting-failure declarations, incomplete reporting or reference failures first; retain exploratory evidence under its actual version. See [qualification diagnostics](curation-lessons.md#diagnose-qualification-before-repeating-expensive-work).

For an unchanged resumed candidate, existing three-round evidence can remain valid after verifying the exact artifacts, receipts, grader, runtime and qualification identity. Record that verification as evidence reuse, not three new executions. Changed inputs require the applicable renewed review and fresh qualification.

Export schema-v2 bundles with `Eab.Candidates.export/2` to `cases/<case-id>/`, including `admission.json`. For a qualified legacy source migration, copy the exact reviewed bundle and retain its equivalent source/review/three-round evidence separately. Rebuild the controller and verify isolation. Both paths use the same manual solver, sealed-submission review and restoration gates. Preserve the qualified upstream reference throughout model validation.

**Ready:** independent review is recorded, all three rounds match the current ensured runtime and qualification identity, source reconstruction and prepared image tree verify, and `Eab.Candidates.verify_admission!(candidate_id)` succeeds on schema-v2 bundles. A source migration preserves an existing legacy contract's format and semantics; it still needs the same manual evidence gates.

## 4. Run the benchmark with Opus twice

### Validation scope and user overrides

The default is two reviewed fresh successes. An explicit user instruction can reduce that count for a named case. Record the instruction, case/version, required count and stop condition in its evidence; retain every other gate unless the user explicitly changes it. Report the actual count and exception. Ash 3031's [single-run approval](../verification/case-curation-2026-10-20/ash-pr-3031/README.md#revised-validation-scope) does not change the default for later cases.

When the user narrows scope during execution, block queued future launches before doing other work and verify the guard. If they authorize the current run to finish, leave that run and its frozen inputs unchanged. Adjust evidence export to the authorized count without fabricating a pair or skipping per-run checks. At the requested stopping point, preserve incomplete evidence outside the validated inventory, restore approved cases once idle, and commit the checkpoint; token pressure alone does not authorize extra runs or relaxed checks.

### Launch and review

Start an ordinary **Run benchmark** on the website with **Claude Code** as the model source and `claude-opus-5-5` at `xhigh` effort, then drive it with `/solve-run` from the dedicated solver session (see [ADR 0010](adr/0010-run-subscription-claude-through-claude-code-harness.md)). The harness declares, without enforcing, the 262,144 generated-token soft threshold, disables compaction where Claude Code allows, and makes no automatic retries. Record the effective settings, harness identity and resolved model the controller reads from the transcript. Keep account identifiers out of committed evidence.

Before each launch, verify the current authorized scope, singleton active inventory, admission, controller idleness and disabled timing observer described below. Record the returned run ID immediately. Wait for grading and cleanup, then review the sealed patch before the next launch. An official pass alone must not automatically start the next attempt while a preservation concern remains unchecked. Start the second run through the ordinary fresh-run path with the same frozen inputs/settings; **Resume is not a second independent attempt**.

Each solver starts with a fresh context and workspace containing only its ordinary visible task/source. Give it no previous repair, reference solution, hidden check or failure feedback. Keep case files, prompts, settings and effective controller implementation fixed across the pair.

Retain every attempt. Diagnose graded failures against the visible contract and exact assertion; distinguish them from established infrastructure interruptions. A justified retry starts fresh and preserves the failed/interrupted record. If a case or environment correction changes frozen inputs, qualify the corrected version and collect a new matching pair. Missing historical run artifacts mean an unknown outcome, not a pass or a discarded failure.

**Ready for approval:** the authorized number of fresh runs completed and passed every required grading dimension under the frozen inputs/settings, with reviewed patches and no unresolved case/grader concern. This means two runs by default; any exception is recorded explicitly.

### Local timing observer

Apply the [shared-machine constraint](../AGENTS.md#shared-machine-constraint): local correctness and model task-success runs are allowed with bounded resources; speed measurement is not. Claude Code reports a subagent's elapsed time when it finishes; do not store it.

Inspect the current `Eab.Measurement` implementation before launch. It currently records `attempt_ms` automatically, so leaving the default observer active is incompatible with this machine's rule. The [Operately 1205 completion](../verification/case-curation-2026-10-18/operately-pr-1205/README.md#completion-on-current-main--2026-10-20) records the working approach and retains the [disabled observer source](../verification/case-curation-2026-10-18/operately-pr-1205/validation-measurement.ex).

For that implementation, install the disabled source and its compiled module only in the idle validation controller, before freezing either run. Preserve the effective source and its hash in evidence so the frozen implementation identity describes the actual controller. Verify `Eab.Measurement.start()` returns `:disabled` and saved attempt/progress records contain the explicit disabled marker, with no `attempt_ms`. A controller recreation restores its image's observer; recheck after every rebuild. If this interface changes, inspect and adapt only the observer, preserving solver and grading behavior. Keep temporary observer changes out of a case-only merge and restore the normal repository controller build after validation.

## 5. Review evidence and park the accepted case

For each pass, verify the sealed submission/completion receipts, final cleanup, patch hashes, usage ledger, completed named acceptance/preservation/submitted results and applicable model-test policy. For bug fixes/features, confirm submitted tests fail in test bodies on pristine source and pass on the repair.

For multiple required runs, compare releases/experiments, model/settings, agent and runtime identities, frozen prompts/instructions/configuration/qualification, and initial requests excluding distinct session keys. For every run, bind its saved qualification identity and complete normalized outcomes to all three reviewed receipts, and its runtime to their image/services/baseline and verified source tree. Agreement between model runs alone does not establish that the earlier qualification still applies. Record unavailable provider revision/seed information honestly.

Read every submitted patch for correctness, weakened tests and grader shortcuts. A valid implementation may differ from the reference or touch fewer files. Preserve all patches, reviews and sanitized result summaries in the case's verification directory, including earlier unsuccessful attempts and amendments.

Once those gates pass, move the **unchanged complete bundle** from `cases/<case-id>/` to `cases_approved/<case-id>/` while the controller is idle. For a migration, preserve the old held bundle outside both active/approved folders before parking its reviewed replacement; do not merge directories. Record bundle hashes and approved status. For a multi-case batch, commit/push the checkpoint on its curation branch, rebuild the controller before the next run, and continue with the next requested candidate. Stop at the requested scope; finishing one candidate does not authorize an open-ended queue.

## 6. Restore the inventory and finish the branch

At batch completion, move every approved case directory from `cases_approved/` back to `cases/`, including newly accepted cases. Check for destination collisions before moving and remove the holding folder only if empty. Unqualified/deferred drafts stay outside the validated inventory.

Verify the original case IDs and complete file hashes against the pre-move record, using each authorized migration's reviewed replacement hashes for that case. Recheck all prepared fork branches against their pinned commits and preserve the recorded excluded bundles/refs. Rebuild/recreate the idle controller from repository source, verify the restored `Eab.Inventory.all()`, check schema-v2 admissions and freeze the restored release without starting another model run.

Review the diff against the branch's main base. A case-only batch should contain the requested bundles, relevant documentation and review/verification evidence; temporary moves, unrequested case deletions, observer changes and unrelated old-branch harness changes must be absent. Commit and push the completed curation branch. Report its name/commit, each accepted case's actual success count and any explicit exception, and that the full inventory has been restored. Single-case validations are not a full-inventory model score.

**Done:** the requested candidates and migrations are accounted for, accepted bundles are in `cases/`, other original bundles are unchanged, controller inventory matches the checkout, and the branch is ready to merge.

## Handoff before an interruption

Update the candidate's tracked verification README before ending an unfinished session. Record the branch/main base, case ID and immutable version, current folder placement, controller inventory/observer state, completed review/qualification gates, every run ID and outcome, any active process/container, retained evidence locations and the exact next action. Commit the checkpoint when possible. Keep raw credentials private and make the next action understandable without ignored `.local` scripts.

An interrupted checkpoint may deliberately leave approved cases parked. Label it unfinished and have the next session inspect active work before moving anything. On completion, always perform the restoration step above.
