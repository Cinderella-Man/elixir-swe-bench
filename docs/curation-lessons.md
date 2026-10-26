# Curation diagnostics and lessons

Use this guide when screening a researched candidate, designing preservation checks, diagnosing qualification drift, reviewing a surprising model result, or resuming expensive work. The [curation workflow](case-curation-loop.md) owns the ordered gates; this guide explains failure modes and targeted diagnostics. These lessons come from [Ash 3031](../verification/case-curation-2026-10-20/ash-pr-3031/README.md), completed on 2026-10-20.

## Screen the exact source before preparing it

A research dossier is a starting point. Check active cases, `cases_approved/`, rejected bundles and curation records before selecting a previously researched PR. A dossier's status can lag completed work.

For an accepted squash repair, inspect the accepted commit's actual parent and complete parent-to-fixed diff. Ash's discovery-time branch base included unrelated changes; the accepted squash parent isolated five implementation files and one test file. Count substantive implementation paths separately from tests and preparation, following the user's requested range. A valid solver can change a different set of files.

Inspect specifically identified follow-up fixes for relevance and record the disposition. Ash's three flagged follow-ups concerned other contracts and stayed outside the reference. This bounded check does not justify absorbing later improvements or searching indefinitely for every possible defect. Preserve exact upstream tests/docs and license notices independently of curator checks. See the [source review](../verification/case-curation-2026-10-20/ash-pr-3031/source-review.md).

Resolve the execution repository and neutral preparation before repeated qualification. Follow [prepared fork sources](prepared-fork-sources.md): existing branches may already be suitable, but their presence does not prove the manifest uses them. The [fork audit](../verification/prepared-forks-2026-10-20/README.md) found reusable Livebook/Plausible branches while the active manifests still referenced upstream. Audit findings, prepared refs, migrated manifests and validated migrations are distinct states.

## Test preservation at consumers, not only at validation

Before freezing checks, write a small matrix of public entry points and relevant input states. Test meaningful interactions across those dimensions rather than every Cartesian combination.

| Dimension | Examples exposed by Ash |
| --- | --- |
| Entry point | Load, map filter, tuple filter, sort, user-facing `filter_input` |
| Input shape | Atom/string keys, scalar/array values, map/keyword containers, malformed containers |
| Value lifecycle | Raw input, cast value, constrained value, expression substitution, typed comparison |
| Absence | Omitted argument, explicit nil value, value normalized to nil, nil tuple container |
| Compatibility | Required/optional/default values, valid ordinary behavior beside rejected input |

Distinguish similar-looking states using the starting source's public behavior. Ash's nil tuple container means omitted arguments and applies defaults; that does not make every nil container valid on every API.

Use non-idempotent custom types when repeat normalization is a risk. A cast that adds one followed by a constraint that doubles the value makes repeated work observable. Check the final result through the consuming query, filter or sort. Inspecting a normalized argument alone missed Ash's later typed-comparison coercion. Assert values and structured errors, leaving representation and helper choices open.

Keep a short requirement-to-check map outside solver input. Review `ticket.md`, appended requirement texts and clarifications together. If an important compatibility outcome remains easy to misread, state that outcome before launching a model. Ash's final clarification named typed comparisons and nil-tuple/default behavior without prescribing its implementation. Repeated misses warrant contract review, not an assumption that the tests or model are automatically wrong.

Evidence: [first submission review and diagnostic](../verification/case-curation-2026-10-20/ash-pr-3031/first-submission-review.md), [minimal wording amendment](../verification/case-curation-2026-10-20/ash-pr-3031/explicit-preservation-review.md).

## Prove checks against wrong solutions, not only the reference

A model's pass shows that a solution passes, not that a wrong one would fail. The review of the first Opus validation run found 16 cases where a plausible wrong or partial solution also passed every check. For each check you add, write down the wrong solution it targets, build that solution as a patch, and show that it passed the old checks and fails the new ones. Run the reference, the model's patch and the untouched starting source beside it.

Recurring gaps:

- **Fixtures that happen to agree with a wrong rule.** If the right answer is also the newest, the first or the last row, then "newest", "first" or "last" pass. Put the right answer in the middle of creation order.
- **Only one path exercised.** A row click but not the player's Next button; the export but not the in-place export or the preview; header and session plugs but not the cookie plug. Cover every path the requirement names.
- **"Nothing is saved" never submitted.** A test that only changes a form proves nothing about saving; submit it.
- **Whole files left out of preservation.** When a few existing tests change on purpose, keep their files in the hidden stage with only those assertions updated, instead of dropping the files.
- **Requirement texts that claim more than the reference does.** Fix the reference when the claim is inside the task; narrow the text only when it is outside.

Make every new check deterministic on the starting source too. Global broadcasts reach every test running at the same time, so filter them by this test's own data. A supervisor restart leaves a gap, so retry in a monitored process. Wait for the operation that carries a value before asserting on it. Run a new check several times, under different seeds, before relying on its starting-failure status.

The grader's own reporter needs the same care: every record it prints must start on its own line, or a progress dot printed just before it hides it from the parser.

## Diagnose qualification before repeating expensive work

Use the first execution as a diagnostic gate before scheduling the remaining fresh rounds. Verify the named starting failures, reference pass, plausible incomplete failure and integrity rejection. A guessed `starting_failures` list can invalidate otherwise informative controls. Retain that exploratory evidence; correct a justified declaration in a new version, preserving every assertion.

Compare complete normalized outcomes across rounds: test identities, pass/fail/completion, failure phases/types and both submitted-test probes. Totals alone can hide missing evidence.

| Symptom | Inspect first | Appropriate response |
| --- | --- | --- |
| Same failure and totals, missing phase/type in one round | Raw reporter lines and truncation status | Reproduce output transport before changing behavior checks |
| Missing tests or incomplete suite | Completion records, setup/import/compiler errors, early exits | Diagnose execution/integrity; absence is not a behavioral pass |
| Unexpected starting failures | Exact named assertions and source pair | Correct the draft's expectation only when the observed failures match the public task |
| Reference fails the claimed behavior | Exact assertion, visible contract and source reconstruction | Resolve or defer before model validation |
| Repeated “qualification” returns the same receipt | Cache lookup and archived receipts | Distinguish reuse from a fresh control execution |

In Ash, a CLI formatter's progress dot prefixed a trusted failure-phase marker. The anchored parser lost a phase even though both runs failed the same assertion. Trace mode did not remove partial writes. A minimal replay isolated the reporting problem; a neutral per-writer line buffer fixed the actual formatter interaction. It preserved assertions and trusted markers, propagated write/finalization errors, and was committed into the prepared fork. This is evidence for that specific preparation, not a universal adapter to install in every project.

Changing the shared grader/reporter has wider identity and revalidation consequences. Diagnose that scope before choosing a fixture correction or separate harness work. See [reporter diagnosis](../verification/case-curation-2026-10-20/ash-pr-3031/reporter-diagnosis.md); its environment overlay describes an intermediate version, later replaced by committed fork preparation.

## Bind qualification to the runtime the solver actually used

The evidence chain is:

**reviewed candidate → three checksummed fresh controls → current runtime and verified source tree → saved run qualification/runtime → sealed patch and grade**

Comparing three controls with each other and two solver runs with each other leaves a gap between the groups. A runtime rebuild can cause one new ordinary qualification while accidentally retaining credit for three old rounds. Before launch, bind all three receipts to the currently ensured qualification identity and exact runtime. After completion, compare each run's saved artifacts with that binding. Verify actual patch bytes against their recorded hash.

Separate identities by purpose. Schema-v2 export adds `admission.json`; that metadata difference is not itself a changed executable fixture. Ash compared executable runtime fields while verifying the complete admitted/frozen bundle separately. Follow the actual artifact schema rather than dropping arbitrary fields to make comparisons pass. Candidate, prompt, source, checks or runtime amendments still require their applicable new-version gates.

Reuse the reviewed [binding implementation](../verification/case-curation-2026-10-20/ash-pr-3031/evidence-binding.exs) only after checking its case-specific assumptions. Its [review](../verification/case-curation-2026-10-20/ash-pr-3031/evidence-binding-review.md) and [isolated drift checks](../verification/case-curation-2026-10-20/ash-pr-3031/evidence-binding-checks.json) document why image, service, baseline, qualification-identity and named-outcome changes must be rejected.

## Keep official grades and acceptance decisions separate

An official pass starts submission review. It does not settle correctness. Ash's first official pass had two source-traced preservation defects; fresh diagnostic workspaces confirmed both. Keep that original grade intact and record the review rejection separately.

For a suspected missed requirement, compare the **pristine source, reference and sealed model patch** using the same narrow behavioral probe:

- Pristine passes, reference passes, model fails: evidence of a preservation regression.
- Pristine fails, reference passes, model fails: evidence of an unimplemented repair obligation, if the visible contract justifies it.
- Reference fails or the probe fails during setup: resolve the probe, contract or fixture before drawing a model-quality conclusion.

A valid diagnostic supports a new immutable version; it does not retroactively alter an old grade. Retain superseded input hashes, controls, patches and dispositions. The stronger-check Ash version failed exactly the two added checks; the later wording-only version received fresh review and controls. Its success belongs to that version alone.

Review seals before naming a patch “success.” Check protected-test changes and shortcuts as well as functionality. A different implementation or file count is acceptable. Review the first completed patch before launching another attempt so a discovered gap does not consume another run on a superseded case.

## Control continuation and leave a usable checkpoint

The [run-scope policy](case-curation-loop.md#validation-scope-and-user-overrides) governs user changes to run count and stopping conditions. A queued pair driver can outlive the instruction that authorized it. Guard the next launch, verify the guard, and preserve an already authorized active run when the user asks it to finish. Blocking a future launch is distinct from cancelling the current benchmark.

For operational issues, inspect the narrowest state that answers the question:

- Before a rebuild, check run/cleanup state **and** standalone qualification leases/cache use.
- After a rebuild, wait for a bounded read-only RPC readiness probe, then verify inventory and observer state. Container startup alone is insufficient. Readiness retries are not inference retries.
- On this machine, install disabled observer source **and the loaded compiled module** before model validation. Rebuilding restores the image's normal observer. During final restoration, verify normal source/beam and a clock-free behavior check; do not start a timing sample to test restoration.
- Stage probes through supported sandbox patch/file paths. Dropped container capabilities can make an ad hoc root write fail before any test executes.
- When model calls pause, inspect run phase and the current bounded command. Distinguish generation, a tool/test command, grading and cleanup. Watchdog limits detect hangs; they are not speed evidence.

Keep new orchestration small and checkpointed. Inspect retained scripts before copying or rerunning them: hardcoded candidate hashes, run lists, output paths and historical two-run assumptions can be stale. Avoid creating migration machinery or launching follow-on work after the user narrows scope. Reuse unchanged, verified evidence; broaden checks only for a specific unresolved concern.

Monitor with compact state queries rather than repeatedly loading full requests, responses or qualification dumps. Report the current phase and meaningful changes; avoid speculative finish times. Saved solver token usage describes that attempt, not the combined cost of curation, reviews and every earlier attempt.

A compact checkpoint should record:

```text
Candidate/version; branch/base; active and parked case locations
Latest authorized scope, required run count, stop condition, queued-launch state
Completed gates and exact evidence files; unresolved concern or deferral reason
Every run ID with official grade and separate review/acceptance disposition
Controller inventory, observer state, active process and cleanup state
Next bounded action; restoration/commit state
```

Preserve sealed patches byte for byte. Blank unified-diff context lines can trigger a whitespace checker when a patch is added as a text artifact; trimming them changes evidence and can break patch application. Check editable prose/code separately and verify the retained patch hash.

When stopping without acceptance, retain the draft/evidence outside the validated inventory and restore original cases once execution is idle. When accepted, restore originals plus the unchanged accepted bundle and verify the normal controller. Report actual success count, any explicit exception, retained failures and deferred work. Ash's [single-run acceptance](../verification/case-curation-2026-10-20/ash-pr-3031/README.md#revised-validation-scope) was explicitly authorized by the user; it is not a general reduction of the default gate.
