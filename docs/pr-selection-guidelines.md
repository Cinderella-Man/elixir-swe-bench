# Selecting and validating realistic developer tasks

Use these rules before spending time preparing a candidate. The next expansion should favor one coherent piece of work that requires understanding and changing several parts of a project. A short ticket can describe substantial work; it should leave the investigation to the solver.

The target remains roughly **100–200 validated cases across several projects**, using the existing Pi runner. This is the current curation guidance, updated after the 2026-10-15 Astra validation and rejection decisions. It is not a new scoring rule or an automated admission feature. See the [admission contract](case-admission.md) for bundle formats and the [validation decision](adr/0009-validate-minimal-tasks-with-blind-model-attempts.md) for the two fresh strong-model passes.

When screening an existing dossier or designing checks, consult [curation diagnostics and lessons](curation-lessons.md) for source-pair verification, preservation matrices and failure triage from Ash 3031.

## Lessons from the first validation cycle

The original v4 pilot retained **nine cases**, each with two reviewed successful Astra repairs. During the [sequential curation loop](case-curation-loop.md), approved folders are temporarily parked outside `cases/`; the folders actually present in `cases/` determine the active set. All eleven examined cases had at least one success; two did not meet admission. The [complete review](../verification/astra-confirmation-2026-10-15/README.md) preserves graded failures and provider interruptions separately.

| Finding | Curation rule |
| --- | --- |
| Plausible 6763's crash was fixed, but a hidden check demanded an unstated CSV column policy. | Verify the visible contract in the exact failing configuration. A test for another configuration does not settle an ambiguous product choice. State the missing outcome briefly or accept defensible alternatives. |
| Plausible 6441's failed repairs avoided the bad imports by also dropping valid ordinary goals. | Pair rejection checks with positive preservation examples. Include mixed inputs that expose fixes which disable a feature or discard legitimate data. |
| Both cases had a successful repair as well as failures. | A strong-model pass establishes one demonstrated solution. A failure still needs diagnosis; neither outcome alone proves case quality. |
| Six interrupted attempts passed when retried in fresh workspaces. | Keep infrastructure errors separate from graded failures, retain the originals, and record retries as new attempts. |

Plausible 6763 and 6441 are preserved under [cases_rejected](../cases_rejected/README.md). The former has a contract ambiguity; the latter lacks the second reviewed success, without an established fixture defect. The folder records exclusion from this release, not a claim of unsolvability. The nine retained cases are a validated pilot, not broad coverage of developer work.

## Prefer coordinated changes across 2–5 implementation files

Make **2–5 substantive implementation files** the main group in new selections. Count tests separately: a one-line fix with four test files is still a one-file implementation task. Include executable application code, templates, styles, migrations and behavior-changing configuration when they are part of the task. Record generated bundles, lockfiles, documentation, fixtures and mechanical edits separately. Count a rename once and explain split/move cases instead of inflating the count.

File count is a discovery signal. The curator must also describe **what has to stay consistent across the changed components** and which behavior demonstrates it. Suitable relationships include a form and its server validation, a query builder and its consumers, or persisted state and the process that owns it. Updating five independent copies of the same string is not the multi-file work we want.

Keep some focused one-file tasks as a smaller part of the corpus. Allow larger coherent tasks when their outcome and environment are tractable. Do not impose a minimum line count, combine unrelated PRs, add make-work, or reject a valid model solution for touching fewer files than the reference. Neither reference patch size nor model failure establishes difficulty.

The nine retained references still have six one-file implementations, two with 3–4 implementation paths, and one with eight paths including a deleted/moved file. These are raw reference-path counts, not difficulty scores. Preserve useful focused cases; use expansion to improve the mix.

## What makes a good candidate

All of these need evidence before admission. During discovery, an unknown is a reason to investigate or defer, not a reason to assume a pass.

| Criterion | Evidence to look for |
| --- | --- |
| Authentic, coherent work | One recognizable user/caller problem or capability, supported by an upstream issue/PR or an independently reviewed request. Its source evidence and intended outcome agree. |
| Meaningful investigation | Finding the cause requires following data, state, ownership or an interface through the project. The ticket does not name the fix. |
| Coordinated implementation | Identify each substantive file's role and the relationship that needs to remain correct. Tests exercise that relationship rather than just individual helpers. |
| Sufficient visible contract | Every scored outcome follows from the minimal ticket and the starting source, tests or documentation available in the workspace. |
| Observable success | Deterministic functional checks distinguish the starting state, a complete solution and a plausible incomplete solution. Relevant existing behavior is preserved. |
| Reproducible environment | The exact historical revision, toolchain, dependencies and local services can be prepared and then used offline. |
| Useful corpus coverage | The task adds a workflow, project, subsystem or task family instead of another near-duplicate. |
| Traceable provenance | Record source revisions, original discussion/request, task/reference authorship and upstream licenses/notices; separate upstream changes from curator-authored checks. |

Prefer tests at the actual boundary affected by the ticket. For a UI/server change, exercise the interaction and the resulting state; for query changes, inspect results using representative local data; for process changes, verify state and ownership through explicit synchronization. Setup failures and watchdog expiry do not demonstrate the requested behavior.

## Give the shortest sufficient task description

For repairs, start with one sentence containing the observed problem, essential triggering context, and “fix it” or its equivalent. Add only facts needed to distinguish reasonable outcomes: an edition, input example, reproduction action or compatibility rule. There is no hard sentence limit. Leave root-cause investigation to the solver; do not leave it to guess product decisions.

For objective refactors, use a concise requirements brief when the repository cannot supply the missing decisions. State observable outcomes, relevant error/state rules, authorization and compatibility constraints. Several sentences or a short list can be appropriate. This is the frozen result of clarification during curation; it does not measure a model's ability to interview a user. Record whether the case uses a short maintenance report or a clarified implementation brief, and show the distinction in corpus summaries.

For features, write a grilled spec in `ticket.md` ([ADR 0013](adr/0013-specify-feature-cases-with-grilled-specs.md)). It is what a developer would hold after a clarifying interview:
- the goal;
- every decided behaviour, with examples;
- edge cases and error behaviour;
- scope and non-goals;
- compatibility constraints;
- the public interface the feature exposes (module and function names, routes, configuration keys).

Keep `grading.requirements` to a short list of key outcomes mapped to checks. A feature may extend its upstream PR into a fuller, coherent feature when the extension follows the project's style and passes its full existing suite. Record the curator extension separately from the upstream PR in provenance.

Illustrative task shapes, not admitted cases:

| Kind | Minimal ticket | Why it can involve several files |
| --- | --- | --- |
| Bug fix | “After I change an item's owner, the old owner can still edit it from an already-open page; fix it.” | UI state, persisted ownership and authorization can disagree. |
| Feature | “Let me cancel a queued export from its status page.” | A user action, job state and cancellation behavior must agree. |
| Refactor | “Move report delivery behind a `Delivery.send/1` interface so callers no longer depend on the SMTP adapter; keep delivery behavior unchanged.” | The requested interface and dependency boundary are explicit and testable. |

Do not include suspected root causes, solution steps, target filenames, reference code or an upstream PR number in the solver's ticket. Public API names or structural constraints belong there only when they are the requested outcome, as in the refactor example or a feature's public interface. Defer a feature while material product choices are unresolved; once settled, state them in the brief rather than hiding them in acceptance tests.

For the rejected CSV case, “Keep the CSV columns unchanged; leave unavailable values blank” would disclose the missing policy without revealing the repair. That is a proposed new version, not a retrospective reinterpretation of its failed attempts.

Review **the whole solver input**, not just `ticket.md`: clarifications, injected requirements, environment notes and visible tests can also give away a repair. Schema-v2 [`TaskContract.instructions/1`](../lib/eab/task_contract.ex) currently appends every `grading.requirements[].text` to Pi's prompt. Those texts may restate the minimal visible contract; they must not become a detailed second ticket. Keep assertion mapping and investigation notes in curator-side review records. Neutral test/environment instructions can remain.

If a hidden check requires one policy and the visible contract permits another, accept both where appropriate, clarify the minimum essential outcome, or defer the case. Do not use the reference author's preference as the requirement. Two strong-model passes do not resolve an unfair hidden requirement by themselves.

## Source candidates deliberately

Historical issue/PR pairs remain the default: they provide authentic context and a concrete reference. Inspect the actual diff, linked discussion and relevant follow-up corrections. Separate incidental refactoring, enterprise-only changes and generated files from the requested outcome; preserve exact upstream reconstruction evidence.

Feature reconstruction and original requests are eligible for small pilots, not a reason to replace the corpus wholesale:

- **Reconstruction:** remove a coherent capability from a pinned working project to create a credible pre-feature state. Record the removal patch, preserve unrelated behavior and legitimate consumer interfaces, and remove answer remnants from comments, history, build artifacts and installed packages. Missing behavior must produce named assertion failures rather than global import or compilation failures.
- **Original request:** write and independently review the outcome brief before the reference and checks. Derive requirements from a real project need. Having one author or model invent the request, implementation and tests does not provide independent contract review.

Apply the same contract, preservation, repeatability and blind-solvability gates to every source. Record source type and related task families. The current importer expects source reconstruction evidence; verify that a new source type fits that contract before preparing a bundle. Runtime or provenance support that is missing remains separate implementation work.

Every runnable case uses a prepared branch in the user's fork. Follow [prepared fork sources](prepared-fork-sources.md): inspect existing branches before creating refs, commit neutral preparation once, preserve the exact upstream repair/reference pair, and verify the built workspace matches the pinned baseline tree. A researched upstream PR is source evidence, not the execution repository.

## Reject or defer these PRs

| Disposition | Examples and reason |
| --- | --- |
| Reject as a source task | Typo-only edits, formatting, generated changes, mechanical upgrades, duplicate/backport/revert copies, or unrelated changes bundled into one task. They do not supply the intended work or independent coverage. |
| Defer for contract review | A feature with unspecified product choices; exact error text or new symbols required only by hidden tests; a “cleanup” with no observable or explicitly requested structural outcome. |
| Defer for execution support | Required cloud accounts, private packages, paid-only source, unavailable historical dependencies, unsupported services/platforms or non-reproducible external data. |
| Defer for grading work | Missing meaningful assertions, nondeterministic behavior without controllable synchronization, a reference that fails the stated outcome, or incomplete solutions that still pass. |
| Defer from this functional benchmark | Work whose only claimed result is faster execution, lower latency or higher throughput. A separate observable correctness consequence may qualify as its own authentic task. |

Large diffs are not automatically eligible; small diffs are not automatically bad. Record the reason, case version and source identity for rejected/deferred candidates so discovery does not repeatedly rediscover them. Preserve removed bundles under `cases_rejected/`, outside the active inventory, with links to the evidence and conditions for reconsideration. Do not pick or discard candidates based on the cheaper models' eventual results.

## Add projects for different kinds of work

Keep application workflows alongside library/framework work. Favor coverage of Phoenix/LiveView interactions, Ecto queries and data constraints, OTP lifecycle/state, background jobs, serialization, authorization, and offline browser behavior. Bug fixes, bounded features and objective refactors are eligible. No numerical project/task quota is established yet; inspect the actual mix at each release and prevent one easy-to-import project or repeated defect family from dominating it.

Before onboarding a project, inspect a historical candidate revision and record:

1. Its license/notices, task provenance, and whether the required code is public in the relevant edition.
2. Its pinned Elixir/OTP/Node requirements, dependency availability, native build requirements, setup commands and local service/data initialization.
3. A suitable acceptance and preservation boundary that can execute offline with the existing adapters, including a way to distinguish test-body failures from setup failures.
4. At least one promising coordinated PR and whether the project offers other distinct task families. Stars, current popularity and raw PR counts are not admission evidence.

The current runner has generic Mix preparation, ExUnit and explicit Node-test adapters, PostgreSQL/ClickHouse service handling, and optional pinned Chromium on its supported runtime. It does not automatically support an upstream Jest/browser suite, arbitrary databases, multi-node topologies or cloud services. Check the historical setup against [`Fixtures`](../lib/eab/fixtures.ex), [`Sandbox`](../lib/eab/sandbox.ex) and the [browser contract](case-admission.md#offline-browser-tasks). If support is missing, record the work separately; do not replace meaningful integration behavior with mocks simply to make a candidate appear runnable.

## Qualify behavior before running a model

Use the existing unchanged/reference/incomplete/integrity controls. For the incomplete control, choose a **compiling, plausible partial solution** that leaves one material part of the workflow incorrect: updating the form but not the authorization boundary, handling one query consumer but not another, or changing durable state without updating the live process. It must fail a named task assertion for the missing behavior, not merely fail compilation after arbitrarily deleting half the patch.

Check each material obligation in both directions: every assertion has visible justification, and every obligation has a discriminating check. A reviewer first reads the solver-visible package without the reference or hidden checks, then maps the assertions back to it. Inspect configuration differences, legacy/new modes, valid/invalid inputs and mixed populations. Include positive preservation examples so disabling a feature or dropping data cannot pass as a repair. Where a particular implementation or representation seems overconstrained, exercise a defensible alternative. Do not require multiple reference implementations for every case.

Require **three fresh qualification rounds with matching named outcomes** before freezing a new case version, following the [recorded repeatability procedure](../verification/frozen-cases-2026-10-15/README.md). Every round must execute the reference, unchanged, plausible-incomplete and integrity controls; reusing a cached qualification receipt does not count. Reusing unchanged prepared images is acceptable when each control receives fresh isolated workspace/service state. Record the test seed, fixtures, relevant clock/timezone settings and synchronization; matching totals alone are insufficient. Repeatability at a recorded seed does not prove freedom from flakiness at every seed.

Grade the submitted patch in a fresh environment, restore protected checks, verify that all required tests actually ran, and distinguish test-body failures from setup failures. Review passing submissions for shortcuts that the checks missed. Run functional checks with bounded resources; watchdogs detect hangs and do not provide speed or performance evidence.

## Freeze inputs and require two reviewed blind successes

After qualification and independent contract review, schedule **two fresh blind attempts with the same strong model, effective settings and frozen task inputs**, through the ordinary Pi flow. Each starts with a clean context and workspace and receives no previous solution, failure feedback, reference or hidden checks. Both passing patches need review. The two successes are feasibility evidence, not proof that all later failures measure model quality alone or that the model always solves the task.

Apply the workflow's [launch/review sequence and explicit user overrides](case-curation-loop.md#validation-scope-and-user-overrides). A case-specific exception records the actual count; it does not change the default above.

Freeze or record the following together:

- Case/source version, exact full prompt including appended instructions, visible files, protected checks and requirement-to-assertion mapping.
- Runtime, service and agent image identities; dependencies, data initialization, test commands/seeds, control outcomes and relevant environment settings.
- Pi version/lockfile, tool schemas, compaction/retry policy, offline network policy and runner/grader identities.
- Model/provider identity and revision when available; reasoning effort, generated-token accounting, hard limits versus soft thresholds, context/response policies and seed availability. Do not claim a fixed serving revision or deterministic seed when the provider supplies neither.
- Every run/attempt ID, submitted patch, named outcome, review and interruption. Public exports omit credentials, account identifiers and private raw traces; retaining local audit evidence does not require publishing it.

The [Astra validation record](../verification/astra-confirmation-2026-10-15/README.md) is an example configuration, not a permanent requirement to use that model or budget. A model or runner interaction, a resource limit, a fixture problem or an unfair check can each explain a later failure. Generous validation and stricter comparison runs answer different questions; declare their policies separately.

### Handle failures without erasing them

| Outcome | Action |
| --- | --- |
| Provider/authentication interruption or independently established infrastructure error | Preserve the interrupted attempt and reason. Explicitly retry the affected cases in fresh workspaces under matching inputs/settings. Count successful retries as new attempts, not repairs to old records. |
| Graded failure | Inspect the patch, exact failing assertion, preservation results and visible contract. Classify it as a repair defect, contract/grader defect or unresolved result. A normal failed test is not a provider outage. |
| Budget exhaustion, timeout or unknown cause | Inspect the stopping stage and evidence. Do not automatically label it infrastructure or case invalidity; retain unresolved outcomes and keep the case outside admission if the gate is unmet. |
| Prompt, check or environment correction | Create a new version, redo affected review/qualification and collect a new pair of blind successes. Keep old results tied to their original version. |

A resume is recovery, not a second fresh validation. An additional diagnostic attempt must have a recorded reason and bounded plan before it starts; it must not become an undisclosed retry-until-pass loop. Report all prior passes, failures and interruptions alongside any later qualifying pair. A selected retry or diagnostic subset is not a full-benchmark score. Do not pool outcomes across changed task versions or incompatible model settings.

The current export API enforces recorded review and fixture qualification, not the three-round or model-solvability policies. For sequential validation, keep only the new candidate folder in `cases/` and park approved folders in `cases_approved/`; no configuration edit is needed. Freeze membership before launching a run and keep it unchanged until the run completes. The dashboard runs the discovered folder set; the controller also supports explicit error retries and selected fresh repeats through the same Pi pipeline. These remain ordinary recorded runs, with no separate agent engine or automatic admission gate.

Publish only cases that meet the gate and have no unresolved contract/grader concern. Removing cases creates a new declared inventory; retain old scores with their original denominator. The v4 nine-case pilot draws on the preserved eleven-case evidence and retries; it is not a newly measured nine-case full-run score. Freeze selection before cheaper-model comparisons and investigate later quality reports without quietly removing that model's failures.

## Public cases and exposure

Keep the current engine and corpus public and reproducible. Public PR repairs may have appeared in training, and removing a public feature does not make its solution unseen. Audit solver images, history, caches and mounts to prevent access to reference repairs or hidden checks during a run; that does not remove prior exposure.

If future claims require unfamiliar tasks, use a separately versioned withheld set of prospective original tasks with the same runner and quality gates. Record exposure and prevent prompts, patches, reports or container layers from publishing its answers. That is a future corpus policy, not a prerequisite for this public pilot or a new execution flow. Two strong-model successes establish neither secrecy nor freedom from memorization.

## Record a decision before building

Use this small curator record in a research note or candidate review; these are not new `case.json` fields:

```markdown
Source type / project / source revisions / PR or original request:
Status: discovered | screened | provisional | admitted | deferred | rejected
Active / parked / rejected / prior-curation records checked:
Prepared fork / existing branch reuse / baseline and reference pins:
Case version / release inventory / public or withheld exposure:
Task kind / family / maintenance report or clarified brief:
Full solver-visible ticket and appended instructions:
Implementation files and each file's role:
Test / documentation / generated / mechanical files (separate counts):
Cross-component behavior to verify:
Visible source for each scored obligation:
Starting-state and reference-test evidence (inspected vs executed):
Plausible partial solution and expected named failure:
Preservation and alternative-solution risks:
Entry-point / input-state matrix and downstream preservation probes:
Runtime / offline services / license evidence and unknowns:
Three-round named control outcomes and frozen-input evidence:
Blind model/settings policy and all attempt IDs (including failures/retries):
Authorized run count / explicit exception / stop condition:
Official grade and separate review/acceptance disposition for each attempt:
Independent contract review / passing-patch reviews / unresolved findings:
Coverage added / related or duplicate tasks:
Admission or exclusion reason / conditions for reconsideration:
Next action:
```

Begin expansion with a small pilot: one coordinated PR from a supported project and one candidate from each of two new projects. Finish source reconstruction, review, fixture controls and blind validation one candidate at a time, retaining a separate commit per case when a bundle is ready. Resolve runtime support once per project, then expand within verified runtime families. A shortlist is discovery evidence, not an admitted-case list.
