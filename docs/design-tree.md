# Application design

The benchmark is a local, single-user Elixir application. Enter a llama.cpp or Strata endpoint, inspect its automatically discovered model details, and start a run. Phoenix LiveView provides setup, preparation, fixture checks, progress, cancellation and saved results.

Current inventory update, 2026-10-15: v4 contains nine cases with two reviewed Astra successes each. Plausible 6763 and 6441 moved unchanged to [cases_rejected](../cases_rejected/README.md): one has an ambiguous CSV policy, the other did not achieve its second success. The [validation report](../verification/astra-confirmation-2026-10-15/README.md) preserves all eleven histories. The [current curation guidelines](pr-selection-guidelines.md) incorporate these lessons. Earlier counts and pending-work statements below describe historical checkpoints.

## Contract

| Area | Decision |
| --- | --- |
| Cases | Nine actual upstream PR repairs: three Plausible, six Livebook |
| Model | One endpoint and its currently served model per run |
| Identification | Server-reported metadata; unknown properties stay explicit; no manual artifact pins |
| Agent | Pinned Pi CLI inside each problem container, using read, bash, edit and write |
| Dependencies | Docker supplies the application, build tools, PostgreSQL and ClickHouse |
| Deployment | Public, portable configuration without personal paths, machine identities or host-specific hardware policies |
| Interface | Local website |
| Context | Detected capacity, capped at 262,144 tokens by default |
| Budgets | Unlimited model/tool calls; up to 8,192 tokens per response and 65,536 generated tokens per case |
| Attempts | One per case, seed 101 by default; advanced settings available |
| History | Persist model details, settings, logs, exchanges, patches and results |
| Interruption | Explicit identity-bound resume; preserve completed outcomes and earlier generations |
| Scoring | Equal case weight; executable checks; incomplete runs have no final score |
| Isolation | Offline attempt workspaces without solutions, upstream history, Docker access or credentials |

## Boundaries

`Model` owns discovery and native token accounting. `Pi` launches the external Pi CLI and records its events. `PiGateway` enforces budgets while forwarding Pi's complete native requests. `Fixtures` prepares pinned Docker environments. `Sandbox` owns isolated workspaces and dependent services. `Grader` qualifies cases and evaluates repairs. `Agent` persists Pi submissions and independently grades them. `Runner` supplies operations to the bounded `Pipeline`; `Runs` supervises one active run and persists its state independently of browser connections. `Release` freezes comparison inputs, `Checkpoints` verifies durable submissions/completions, `Retention` protects shared cache state and `Evidence` summarizes factual grading results. `Store` owns local artifacts and compact history summaries. The website presents these operations.

Docker host networking allows the controller to reach loopback model endpoints. The website itself binds only to loopback; fixture containers have no external network. Execution begins when the user clicks Run. Source inspection, builds, synthetic correctness tests and metadata discovery work without benchmark execution.

See [evaluation](evaluation.md), [operation](runbook.md), and the [decisions](adr/0003-single-model-website.md).

## Preparation and cache pipeline

Cold baseline preparation follows ascending PR number within each repository/runtime family, including earlier prerequisites outside the lookahead window. Qualification stays inside that window. Exact baseline hits bypass preparation ancestry. Once the first Pi attempt starts, two preparation workers fill a four-case window by default. Pi attempts follow inventory order, and at most one additional pristine workspace waits with its services started. A single grader consumes saved submissions independently; one submission may queue behind it before new Pi attempts pause.

| Branch | Decision |
| --- | --- |
| Agent concurrency | The run's parallel attempts, 1 by default ([ADR 0014](adr/0014-run-a-runs-attempts-in-parallel.md)) |
| Model location | Assume a remote model for resource planning; local endpoints remain supported |
| Readiness | Prepared image plus valid qualification, with only the next workspace kept live |
| First case | Prepare it exclusively until its attempt starts |
| Ordering | Inventory order; wait for the next case when necessary |
| Capacity | At least four upcoming cases and two preparation jobs; one waiting workspace and one grader per parallel attempt; preparation bounds are configurable |
| Failure | Retry safe transient connection failures within a request up to five times; record terminal case errors and continue unrelated cases; no automatic case retry or final score for an incomplete/error run |
| Cancellation | Stop all workers and drain subprocesses before removing installation-owned containers |
| Restart | Preserve evidence, mark unfinished work interrupted and clean up; explicitly resume under unchanged release/model/settings |
| Cache scope | Same Docker host across runs, model changes and restarts |
| Cache identity | Independent project, service baseline and Pi inputs; grading evidence has its own relevant baseline/contract/evaluator identity |
| Reusable state | Pristine source snapshots, compatible pristine build seeds, shared package downloads, immutable broken-source and database images, separate Pi attachments and matching qualification receipts |
| Progress | Independent per-case phases/messages; the active Pi keeps foreground priority |

`Pipeline` owns the bounded scheduling and worker cancellation barrier. `Runner` supplies preparation, workspace, submission and grading operations. `Agent` persists a submission before independent grading, and `Source` caches pristine upstream snapshots. `BuildCache` selects immutable preparation seeds by repository and installed toolchain; source reconciliation and dependency invalidation run inside each historical runtime. Shared package caches are separate from compiled artifacts. No agent or grader modifications enter the reusable cache. A fresh final image excludes superseded source layers, and Pi attachment follows project compilation.

Bounded synthetic checks cover overlap, ordering, preparation limits, grading backpressure, failure isolation, cancellation, progress and cache reuse. Source inspection and correctness checks on this shared machine do not establish speed improvements. Performance qualification requires a separately authorized suitable environment.

See [the pipeline decision](adr/0004-overlap-preparation-and-grading.md), [reuse across PR revisions](adr/0005-reuse-pristine-builds-across-revisions.md) and [configuration and caching](runbook.md).

## Persistent case baselines — foundation implemented

The intended use is evaluating 10–30 models against the same PR cases on one Docker host. The goal is to reuse each case's complete pristine preparation across those runs until explicitly cleared. Completed baselines provide reuse of the same case across models; cross-revision project and database seeds reduce the work needed to prepare those baselines the first time.

### Confirmed choices

| Branch | Decision |
| --- | --- |
| Missing or stale preparation | Run automatically prepares what is missing; no mandatory separate preparation step or cache-only run mode |
| Consumers | Independent Pi workspaces, grading workspaces and broken-source regression probes share a pristine baseline through isolated writable clones |
| Model sequence | Complete the frozen active inventory for one model, then run the same inventory for the next model; every case's baseline persists across those runs |
| Starting-state contract | Application repairs start after the original broken revision's installation and migrations; future installation/migration cases explicitly request fresh setup |
| Database seeding across PRs | Prepare an oldest compatible pristine database base, clone it for later cases, apply only their missing migrations, then retain each case's completed baseline for all model runs |
| Existing scheduling | Keep the run's parallel attempts, the bounded preparation window, waiting workspaces and independent grading |
| Measurement | Source inspection and correctness evidence only on this machine; no timing promises or performance qualification |

### Established facts

`Fixtures.ensure/3` already reuses an unchanged case image without fetching or building, and `Grader.qualify/3` already reuses matching valid qualification evidence. Model endpoint and token-budget changes alone do not invalidate these caches. A failed Pi attempt does not invalidate them either.

Before this change, `Sandbox` started empty PostgreSQL and ClickHouse services for every Plausible workspace. All six saved Plausible revisions prefix `mix test` with `ecto.create --quiet` and `ecto.migrate`, repeating database initialization. The new dedicated pristine preparation runs those two commands before any test helper, test body, reference patch or agent is introduced, then captures stopped service state for independent clones. `ecto.setup` is unsuitable because it also seeds demo users/sites absent from the existing test setup. Migration-created lookup data, dictionaries and functions must survive along with schema and migration receipts. Bounded synthetic checks cover this mechanism. Two real cases passed current qualification; the user stopped the remaining checks. See the [validation record](validation-2026-10-14.md).

Livebook has no database services in the current manifests. Its compiled filesystem is reusable, but its tests deliberately reset local storage and start process-local runtime state. Preserving a running BEAM or suppressing those resets would change test semantics.

The saved Plausible runtimes use PostgreSQL 16 for cases 5939/5956 and PostgreSQL 18 for 6300/6441/6449/6763. Their declared volume roots and data-directory layouts differ. Pin each baseline to its actual engine image and layout; never infer these from another case's tag. Current migration sources use local ClickHouse dictionary connections and standalone tables, but publication must verify the realized catalog has no replicated engines or external dictionary dependencies. Some data migrations enqueue asynchronous mutations, so successful migration command completion alone is insufficient: pending mutations must finish without errors before clean shutdown and capture.

The prepared-application contract deliberately changes grading order: the original broken revision initializes service data before a submitted or reference repair is applied. A patch therefore does not retroactively affect that original initialization. Requalify the existing cases once under this contract; future installation/migration cases retain an explicit fresh-setup policy. See [the starting-state decision](adr/0006-grade-repairs-from-prepared-baselines.md).

Cache identities previously coupled unrelated changes: Pi package/bridge changes entered the project recipe, while qualification included broad runtime, case-directory and controller inputs. Project, service and Pi artifacts now have separate identities; executable qualification covers relevant baseline, case-contract and evaluator inputs. Model, budget, UI, logs or descriptive metadata do not recreate the application/database baseline. Unknown case-contract fields invalidate qualification by default. Public prompt changes enter the immutable release identity even when executable controls remain unchanged; new candidates require recorded independent review and identity-bound admission evidence.

### Component structure

1. **Project artifact:** exact broken source, dependencies, generated assets and compiled application/test-support, without agent or grader state.
2. **Service artifacts:** complete pristine initialized database state tied to the exact service image identities, data-directory layout and preparation commands. Capture only after clean shutdown; publish all components atomically.
3. **Agent runtime:** separately versioned Pi/Node/bridge, attached without reconstructing the project or database baseline.
4. **Qualification receipt:** baseline identity plus acceptance/reference/control fixtures, test contract and evaluator identity. Requalification can use the existing baseline without rebuilding it.
5. **Disposable workspace:** independent writable clones, never writable shared database directories. Neither agent output nor qualification mutations can flow back into the baseline.

### Database seeds across PRs

The user additionally requested that an oldest PR's initialized PostgreSQL/ClickHouse images seed later PRs. Treat this as a second cache level: a compatible shared database seed avoids replaying old migrations during initial preparation, while the exact completed baseline avoids all migration work when another model runs the same case.

Select bases by verified migration compatibility, not by PR number alone. Never advance the shared seed in place: migrate an isolated clone with the target's pristine source and publish a new immutable artifact. Later preparations may select the closest compatible completed state, so they need not replay migrations already present in another suitable seed. Preserve the PostgreSQL/ClickHouse pairing where bootstrap operations depend on both services.

Database engine families are separate. The current cases use PostgreSQL 16/ClickHouse 24 for 5939 and 5956, versus PostgreSQL 18/ClickHouse 25 for the other four. Reusing raw data directories across PostgreSQL major versions requires an explicit database upgrade, not ordinary application migrations; see the [PostgreSQL upgrade contract](https://www.postgresql.org/docs/18/upgrading.html). This design uses separate pinned engine bases rather than adding cross-engine upgrades to preparation.

Require matching engine/configuration/layout identities and an unchanged, ordered prefix of applied migration contents. Account for migration helper code, SQL templates, static data, adapter behavior and other declared bootstrap inputs: matching filenames or version numbers alone do not establish equivalent initialized state. Deleted/rewritten migrations, an added migration below the seed's applied frontier, changed bootstrap semantics or an unknown dependency reject that seed. Prefer an earlier verified seed, or prepare a new shared prefix stopping before the first incompatible migration; otherwise initialize a fresh compatibility group. Never roll back or edit a completed seed to manufacture the earlier state. A successfully qualified target case does not by itself prove that its initialization is equivalent to a fresh bootstrap.

Prepare each missing baseline once in PR order within its runtime family so the next can consume the completed build seed. Independent families can prepare concurrently under the worker limit. Database artifacts still select any verified compatible ancestor and physical image depth remains bounded; logical scheduling does not create a 250-layer image chain. A cold first case may require preparation of its seed before it can start. Once the case baseline exists, subsequent model runs bypass this dependency graph entirely.

The saved source trees have the following content-prefix order. No numbered migration file is edited or deleted along this sequence; notably, PR number order would put 6441 in the wrong position.

| Case | PostgreSQL migration files | ClickHouse migration files | Engine family |
| --- | ---: | ---: | --- |
| 5939 | 221 | 52 | PostgreSQL 16 / ClickHouse 24 |
| 5956 | 223 | 52 | PostgreSQL 16 / ClickHouse 24 |
| 6300 | 228 | 52 | PostgreSQL 18 / ClickHouse 25 |
| 6449 | 230 | 54 | PostgreSQL 18 / ClickHouse 25 |
| 6441 | 241 | 55 | PostgreSQL 18 / ClickHouse 25 |
| 6763 | 242 | 55 | PostgreSQL 18 / ClickHouse 25 |

The oldest candidate bases are therefore 5939 and 6300, but engine groups alone are insufficient. In the second group, ClickHouse migration `20241111084056_create_acquisition_channel_column.exs` calls `Plausible.DataMigration.AcquisitionChannel.run/1`, which reads SQL templates and current acquisition-source mappings; these inputs change between 6300 and 6449. Target migration `20260601000002_update_acquisition_channel.exs` explicitly rebuilds the dictionaries/functions, making forward reuse plausible, but equivalence still needs semantic verification. A shared ClickHouse prefix before the original affected migration would retain 37 numbered migrations and leave 15–18 target migrations, provided its own dependencies are compatible.

PostgreSQL migration `20200529071028` calls unversioned `Oban.Migrations.up()`. The Oban package changes from 2.20.1 to 2.24.1 before 6441, so the same migration file can install a different Oban schema. A prefix before it retains 74 numbered PostgreSQL migrations, but changing Ecto/Postgrex versions still require a justified compatibility policy; file counts alone cannot certify equivalent execution. Later data-migration helper modules also change. These are correctness constraints on cross-PR reuse, not reasons to discard an exact per-case baseline on later model runs.

Preserve cross-repository ordering when choosing partial prefixes. The configured order is PostgreSQL then ClickHouse, and PostgreSQL migration `20240528115149_migrate_site_imports.exs` can open ClickHouse through `SiteImports` in Community Edition. An earlier migration also invokes `Repo.update_all(Plausible.Site, ...)`, so dependency analysis must include referenced application schemas, not only dedicated migration-helper modules. Independently chosen PostgreSQL and ClickHouse prefixes are not automatically a valid paired seed.

Keep this policy conservative: record and hash the declared bootstrap dependency closure, reject unknown changes, and cover declared compatible combinations with bounded semantic checks. Do not silently replace fresh-target initialization with a different historical upgrade path merely to reuse more migrations. Preparation logs must identify the chosen seed, skipped/applied migration versions and rejection reason. The design promises reuse of compatible preparation, not that every PR always needs only a handful of migrations.

### Lifecycle and user-visible behavior

Use content-addressed records and retain selected versions until explicit cache removal. Ordinary run cleanup deletes writable clones, not baselines; controller replacement must preserve the catalog and artifacts. A missing component makes the baseline unavailable and is repaired automatically on Run. Separate persistent artifact ownership from run-owned and waiting workspace ownership so cancellation cannot delete reusable state.

Freeze baseline identities for each run and lease those exact artifacts to its consumers. Updating a catalog pointer cannot change the starting state halfway through a run. Concurrent requests for the same missing baseline share one preparation operation; cancellation or failure leaves no reusable completion record until all components have been verified. Retain completed baseline components if later fixture qualification fails, but do not mark the case ready until valid controls exist.

Do not re-resolve mutable upstream image tags or require network access on a valid cache hit. Save the exact resolved engine/toolchain identities with the baseline; changed declared preparation inputs or an explicit refresh select a new version. Keep run provenance, including the full inventory and agent identity, even when those details are intentionally excluded from preparation or qualification cache keys.

Expose per-case baseline availability and the reason for any rebuild or requalification in the website and activity log. Distinguish restoring a saved baseline from preparing a missing one, fixture qualification from submission grading, and actual repair compilation from cached setup. Provide explicit per-case/all-unused cache removal; refuse removal of artifacts leased by an active run. External Docker image pruning can still remove cached artifacts, which the next Run detects and repairs.

| Event | Required work |
| --- | --- |
| First preparation of a case | Prepare the project, initialize pristine services, capture and publish their state, then qualify using disposable clones |
| Next model, unchanged case and evaluator | Reuse project/service artifacts and qualification; start isolated processes and attach the current Pi runtime |
| New Pi version | Rebuild or attach the agent runtime without recompiling the application or reinitializing its databases |
| Changed acceptance checks/evaluator | Requalify fresh clones of the existing baseline; do not rebuild unrelated preparation |
| Changed source, preparation contract or service identity | Rebuild affected preparation and qualify the resulting baseline |
| Model edits source or database content | Keep those changes in disposable workspaces; compile changed code and run tests normally |
| Run ends, stops or controller restarts | Remove owned disposable workspaces; preserve published baselines and valid receipts |

An image alone does not capture mounted database volumes: [Docker commit excludes mounted volume data](https://docs.docker.com/reference/cli/docker/container/commit/). PostgreSQL's [file-level backup contract](https://www.postgresql.org/docs/16/backup-file.html) requires a stopped server for a plain complete-directory copy, including transaction state. The service capture must inspect pinned image configuration instead of assuming one PostgreSQL major version or data path.

Prefer immutable on-disk artifacts and fresh processes. [Docker checkpoint/restore](https://docs.docker.com/reference/cli/docker/checkpoint/) remains experimental and requires CRIU; it is not the default recommendation.

The proposed storage representation is initialized service images with data at explicit paths outside inherited `VOLUME` roots, plus each disposable container's private writable image layer. This avoids an application-managed full data-directory copy for every workspace; it does not eliminate service startup or filesystem copy-on-write work. Docker documents both the isolation mechanism and the write overhead for databases in its [storage-driver guide](https://docs.docker.com/engine/storage/drivers/). This is a deliberate choice for disposable test databases; no speed claim has been established on this machine.

Both pinned PostgreSQL images honor `PGDATA`; place the complete cluster at `/opt/eab-state/postgres` and preserve ownership and restrictive permissions. Both pinned ClickHouse entrypoints obtain the main data directory from XML; relocate its complete data root and related persistent paths together, preserving database/table UUIDs while giving each clone its own server identity. Keep the pinned stock startup behavior and verify it recognizes initialized state. Paths inherited as volumes remain unused; ordinary clone cleanup removes these incidental volumes.

Capture from a stopped preparation container only after verifying that every durable database path is inside the captured filesystem, not an excluded mount. A service successor may inherit its compatible database seed image as a layer; it must retain the target's exact engine identity and cannot silently inherit different server binaries. Docker's [volume behavior](https://docs.docker.com/engine/storage/volumes/) matters: mounting an empty volume over image data copies that data, while an existing volume hides it. If correctness checks reveal a service cannot use relocated storage safely, use a complete stopped-state snapshot restored into a private volume for that service and report that restoration work explicitly.

### Confirmation and expansion

The user confirmed this design on 2026-10-13, including persistent baselines on disk, services starting on Run, and preparation of the next workspace during the current attempt. The original baseline design no longer requires another confirmation. The user then requested a plan to expand toward 250 PRs each from Plausible and Livebook; see [the expansion plan](benchmark-expansion-plan.md) for the additional catalog, storage and execution work and the confirmed scope. The baseline foundation is now implemented with bounded correctness coverage; the updated controller is deployed, and real fixture qualification stopped at the user's request after two of twelve cases passed. [SWE-bench research](research/swe-bench.md) is complete and incorporated into the plan; no new cases were added.

The expansion scope is now confirmed: bug fixes, features and objectively checkable refactors, including offline-testable JavaScript/browser work, with completed-case recovery for interrupted runs. Task kinds need distinct acceptance/coverage contracts, while the original twelve-case release stays intact. See [the grading decision](adr/0007-grade-features-and-refactors-by-explicit-contracts.md) and [the recovery decision](adr/0008-resume-completed-case-checkpoints.md).

The research follow-through implements immutable release fixtures, exact source export receipts, identity-bound resume, retained baseline roots and shared-reference removal, pre-build free-space checks, compact history/case pages and named failure evidence. Saved patches resume grading; unfinished Pi generations are archived before fresh execution. Completed passes, failures and evaluation errors are not silently retried. Project/task breakdowns use the frozen case metadata. Candidate review/admission records, feature/refactor contracts and Node/browser adapters now have synthetic correctness coverage. The existing twelve sources pass fixed-tree reconstruction; two have current executable qualification, with the remaining ten unverified under the deployed evaluator. No new candidates have been admitted.

### Correctness criteria for implementation

- Reusing a valid baseline invokes no source download, package installation, project build, schema migration work or fixture controls. Lightweight identity/readiness checks remain; ordinary test aliases may check that migrations are current.
- Changing only model/budget/UI/logging metadata preserves baseline and qualification identities. Relevant project/service changes rebuild affected artifacts; relevant acceptance/evaluator changes rerun controls without rebuilding unrelated artifacts.
- Two simultaneous clones start from the same state; mutations or deletion in one cannot affect the other or the baseline. Repeat after cancellation and controller restart.
- Reject incomplete publication, missing artifacts and incompatible engine/data-layout identities; rebuild only affected preparation and preserve other cases.
- Verify database-seed selection against full migration identities and bootstrap dependencies, including changed historical helper code, unversioned library migrations, non-prefix histories and engine changes. Prove a migrated clone cannot alter its seed; verify final target schema and migration-created data with semantic checks independent of fixture pass/fail alone.
- No reference repair, hidden check, test-created data, transcript, agent configuration or credential is present in a published baseline.
- Baseline tests and all existing qualification controls must work from clones. Actual repair changes can require recompilation and tests still execute; neither is reusable setup work.
- Bounded synthetic tests prove scheduling and cache bypass by observed operations, not elapsed-time assertions. Real performance qualification requires a separately authorized environment.

## Subscription model validation — design interview, 2026-10-15

Status: Q1–Q6 confirmed and one-flow scope clarified by the user. The user wants to use their ChatGPT subscription to have a strong model solve the eleven cases, then evaluate progressively cheaper models and grow the curated benchmark to roughly 100–200 cases in total. The minimal symptom-only tickets remain an explicit requirement. The provider implementation now uses the existing connection and Pi run flow. No real account-authorized model run has been performed.

### Evidence and limits

- Existing [fixture qualification](verification/task-quality-promotion-2026-10-14.md) accepted all eleven references, rejected unchanged/incomplete/bypass controls, rejected fourteen targeted wrong repairs, accepted two valid alternatives, and repeated the eleven reference acceptance suites under another test seed. This establishes the recorded controls, not exhaustive correctness or a model success rate.
- The one-sentence tickets change the frozen release. [Executable qualification](../lib/eab/inventory.ex) excludes descriptive ticket contents, so retaining those receipts does not establish that the abbreviated prompt fairly conveys every scored requirement. The promotion report's earlier statement about ticket coverage describes the earlier tickets.
- The actual solver input includes the ticket, starting source and tests, and [agent instructions and case clarifications](../lib/eab/agent.ex). Review that entire visible bundle when judging discoverability. A blind attempt must not receive reference repairs, hidden checks, prior solution transcripts, or upstream history.
- A successful strong-model attempt demonstrates one accepted solution under its recorded conditions. It does not prove the grader rejects every wrong solution, accepts every valid alternative, or that all failures of other models have the same cause. Public upstream cases also permit prior model exposure.
- One concrete ambiguity remains after shortening: [Plausible 6449](../cases/plausible-pr-6449/ticket.md) reports mutable link URLs and foreign-site segment attachment, while its [acceptance checks](../cases/plausible-pr-6449/acceptance.patch) require invalid segment edits to save successfully and clear the old association. Read-only inspection of the checksum-verified starting source at `ebf1fd81bd2e6884b5d31496b9f902cc337f1476` found changeset/foreign-key validation and an error-form path, with no clear-and-save fallback or visible test requiring it. Rejection of malformed/nonexistent IDs is a source-based inference, not a new execution result. The [reference repair](../cases/plausible-pr-6449/reference.patch) introduces save-and-clear. A targeted complete alternative should preserve legitimate edits and explicit empty-selection clearing while rejecting invalid selections without changing stored data. It remains to be implemented and exercised against revised checks. The read-only review of all eleven tickets found no equally strong additional missing-policy example.
- OpenAI documents [ChatGPT plan usage for locally hosted apps](https://developers.openai.com/siwc/token-sharing-open-source), with account-authorized [model discovery and Responses requests](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference). The provider path now supports app-owned OAuth registration, account-specific models and native Responses alongside llama.cpp and Strata. Actual account/model eligibility has not been tested.
- The subscription route's [preview restrictions](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations) reject `max_output_tokens`; exact input-count endpoint access under that authorization remains unverified. The current hard output limits cannot be assumed equivalent. The implementation records a soft threshold checked between responses and provider-enforced context, with null strict caps and seed. Differing effective policies cannot join a direct score comparison.

### Confirmed decisions

The user confirmed Q1–Q6 and clarified that subscription access must use the existing run flow. See [the validation decision](adr/0009-validate-minimal-tasks-with-blind-model-attempts.md).

| Decision | Confirmed answer | Decisions it unlocks |
| --- | --- | --- |
| Q1: What qualifies a case for the cheaper-model comparison? | Independent fixture and prompt/check review plus a blind strong-model pass; the pass is solvability evidence, not a bug-free certificate | Required attempts, failure triage, review ownership and handling cases the strong model cannot solve |
| Q2: How should underspecified behavior be graded? | Keep minimal tickets; ground requirements in visible source/tests/docs, and permit defensible alternatives when no visible contract chooses a policy | Resolution of the shared-link example and assertion mapping |
| Q3: What is being compared? | Keep Pi for the time being, with the same tools, visible inputs and isolation across models | Subscription integration, model/reasoning choices, comparable budget policy and the meaning of cheaper |
| Q4: Is the subscription run solvability evidence or also a directly comparable score? | Generous recorded settings establish solvability; stricter comparisons remain distinct evidence, using the same execution flow | Provider-specific effective settings must remain explicit; a pass with more resources does not prove success under smaller budgets |
| Q5: How much blind model evidence is required? | Two fresh attempts per case with the same model and settings; retain all outcomes and investigate disagreements | Twenty-two planned attempts for the current eleven cases; resume does not count as a second fresh attempt |
| Q6: What if a case still fails validation? | Diagnose and leave unexplained cases unresolved; hold the intended complete comparison until its cases are resolved | Do not quietly drop cases, retry until passing, or weaken checks to obtain 100%; new unresolved candidates remain outside the admitted inventory |

Accepting multiple valid implementations does not require inventing multiple reference solutions for every case. Retain the upstream reference and targeted wrong-repair controls; add a materially different valid repair when it probes a concrete risk of rejecting reasonable behavior. The existing Markdown and Erlang diagnostic alternatives illustrate this approach. Alternative repairs are curator-side controls and stay outside solver workspaces.

### One execution flow

The user explicitly rejected building a separate validation flow. Enter an OpenAI endpoint in the existing connection area, authorize the ChatGPT subscription, choose an available model, and use the same Run action, Pi tools, fresh workspaces, grading and saved results. Two ordinary new runs provide the two blind attempts. Validation describes how their evidence is used for curation, not a separate execution mode.

The first implementation scope is OpenAI provider support, app-owned subscription sign-in, account-specific model selection, and honest effective settings within the existing UI. Following the user's statement that endpoint access and authentication are enough and they will verify each case twice, the two-run curation rule uses saved evidence and repository admission changes. A dedicated candidate dashboard, alternate runner, automatic admission and bulk PR discovery are outside this first step.

There are real provider differences to represent without creating another flow. The official subscription path uses browser OAuth and the public Responses endpoint, not a pasted Platform API key. OpenAI serves multiple account-specific models, so the connection needs a model selector. Unsupported response caps, input-count access and seed behavior must not be presented as enforced. A generous cumulative stopping threshold checked between complete responses is the implemented policy for subscription runs; save the actual usage and effective policy, and exclude differing policies from direct score comparisons. Credentials remain outside solver workspaces and saved evidence.

Current code runs the entire configured inventory and does not expose candidate batches. Candidate admission currently records independent review and executable fixture controls, not model passes. Adding an automated two-pass gate later would require carrying frozen candidate inputs through the same runner and linking ordinary completion receipts to admission; it should not create a second execution engine. Existing draft/repository curation can remain manual in the first implementation. Future schema-v2 cases currently inject requirement text into Pi instructions; expansion must preserve the agreed minimal task description rather than quietly reintroducing a full specification there.

The design frontier for this first step is settled. Provider/account conformance, exact generous settings and selected model are execution prerequisites, not reasons to invent another product flow; no specific account entitlement or selected model has been verified. Any ticket/check revision requires revalidating the affected evidence and keeping comparison runs on the same release. New unresolved drafts do not invalidate an already validated release, and cases are not silently removed from an agreed comparison set.

The glossary now distinguishes **solvability validation** and **prompt sufficiency review** from **fixture qualification**. A rejected repair is not automatically a model-quality failure: its evidence may instead identify a case ambiguity, grader defect, infrastructure problem, or an unresolved cause.

Implementation verification: [ChatGPT subscription provider](verification/openai-subscription-2026-10-15.md). The default functional suite passes 146 tests (5 Docker-tagged tests excluded), the production image builds, and the updated dashboard is deployed. Real account-authorized inference and the two fresh case-validation runs remain unperformed.

## Realistic PR scope and additional projects — 2026-10-15

The user wants to expand beyond the current projects and prioritize the multi-file work common in their own tickets, typically spanning 2–5 files. The [static scope audit](verification/case-scope-audit-2026-10-15.md) finds that seven of eleven current reference solutions touch one implementation path, three touch 3–4, and one touches eight including a deleted/moved path. This is a scope description, not a measured difficulty ranking.

The [selection guidelines](pr-selection-guidelines.md) use 2–5 substantive implementation files as the main discovery preference, counting tests and generated changes separately and requiring an explanation of the coordinated behavior. File count is never a submission requirement; simpler correct implementations remain valid. Keep minimal tickets, inspect injected schema-v2 requirement text as part of the prompt, and retain the existing fixture/review/two-pass solvability policy.

The [upstream candidate research](research/multi-file-pr-candidates-2026-10-15.md) begins project and PR screening. Candidate findings do not change the eleven-case inventory or establish runnable new project environments. Start with a small pilot across a supported project and two additional projects, finish each case before bulk expansion, and continue using the ordinary Pi flow. The previous 250-cases-per-project target is superseded by the total 100–200-case direction.

## Results presentation — 2026-10-17, updated 2026-10-18

Status: implemented in `results-page/`, named **Elixir SWE Bench** by the user. The page is separate from the local runner and prepared for GitHub Pages. No repository rename or public deployment has been performed.

### Confirmed decisions

| Decision | User direction | Implementation |
| --- | --- | --- |
| Audience | A shareable results page | Static HTML/CSS/JavaScript with an Elixir exporter |
| Entry | One completed run per point | Separate rows for repeats, no averaging or pooled attempts |
| Additions | New model/quantization results should be easy to add | `mix eab.results add` creates one public JSON record; the build discovers all records |
| Presentation | Minimal content, no comparison selector or model search | Title, model-size slider and one continuous plot with labels left of the dots; cases and settings open below it |
| Cases | Show the nine valid cases, excluding rejected cases from Astra's details too | Astra 9/9, Flash 8/9, Swift Qwen 27B 5/9 and Qwen 27B 2/9; axis spans 0–9 |
| Model labels | Exact artifact name and quantization in the benchmark itself | Discovery, saved-run history, run headings, comparisons and new reports use normalized identity; transport keeps the routing alias |
| Size | Keep model size and allow a maximum size | The slider uses weight-file size, so missing runtime measurements do not hide known-size models; observed VRAM/RAM remains separate deployment data |

### Publication contract

The exporter requires a completed full-inventory source run and final pass/fail outcomes. It selects the current admitted cases only after checking that their saved fixture hashes match the current files. Removed cases are absent from the public records and expandable details. Original run evidence remains intact. The public schema records source release identity and per-run settings; these rows do not imply identical evaluation policies. The local benchmark's strict comparison checks are unchanged.

Public records exclude endpoint addresses, account identifiers, transcripts and raw provider metadata. The builder validates the current inventory, fixture hashes, distinct run IDs, settings and metadata. A future case change requires explicitly refreshing eligible records or obtaining new runs. Missing model metadata stays unknown; optional publisher overrides have explicit provenance.

The two 27B models report 17,431,404,544 bytes each. The Flash model's two served GGUF files total 83,863,586,496 bytes. These values are weight sizes, not total VRAM requirements; context and runtime need additional memory. Astra is labelled API. The model-size slider includes both 27B models at 50 GB, with All restoring every row. A loaded Strata process at a configured 262144 context was observed with 69.8 GB GPU allocation and a 51.5 GB service-lifetime RAM peak; these are separately dated deployment observations, not saved-run memory peaks. The collector attributes GPU memory to the actual process and devices, avoiding Strata hardware telemetry that selected other physical GPUs. Other local model memory profiles remain uncaptured.

The GitHub Actions workflow validates records and builds only `results-page/dist/` for Pages. One-time setup and normal additions are documented in [the page README](../results-page/README.md). Links follow `GITHUB_REPOSITORY` during Actions builds, accommodating a later repository rename. The page needs no server, database, npm dependencies or external assets at runtime.

The glossary records **Published result**, **Model identity** and **Model weight size**. These presentation and static-hosting choices are readily reversible, so no new ADR is needed.

On 2026-10-20 the user requested permanent case timing, with model inference served on their other machine. Every attempt now saves elapsed milliseconds from Pi startup through completion; preparation, queueing for grading and grading are excluded. The optional timing flag, environment labels and separate request-throughput accounting were removed. Public schema version 4 retains case duration, generated tokens, model calls and the host thinking preset with its source. Existing run history and published results were cleared because their thinking presets were uncertain. Functional tests use synthetic clocks; memory collection remains independent.


Run memory collection is implemented as a run-owned SSH stream from the model host. A first sample and matching model/context are required before work starts; completion, error and cancellation finalize the stream. Dedicated service cgroup counters and process-attributed NVIDIA allocations exclude unrelated workloads. Raw samples and session summaries persist with each run; gaps, disconnects and interrupted/resumed segments retain partial coverage. Public export automatically carries hardware and sampled peaks without private host/service/GPU identifiers. RAM plus VRAM is a simultaneous sampled total, while each resource retains its own peak and per-GPU breakdown.

## Selecting future new cases — 2026-10-18

Status: closed at the user's request. No case-selection or combined-result feature is being pursued from this discussion.

The user decided to omit Astra from the published model comparison and plans to add an explanatory note. Astra supplies solvability validation: every admitted case must have the required successful Astra evidence, so its success on the admitted set is an admission condition rather than an independent comparison score. This supersedes the earlier decision to show an Astra result on the public page. It does not require rerunning every old case together with each addition.

Successful model attempts support solvability; they do not prove that a case or grader is free of bugs. The existing fixture qualification, prompt review and two-fresh-success policy remain applicable. The user closed the discussion without requesting a website edit or a new execution feature.

### Established facts

The dashboard currently starts the entire configured inventory. The executor already operates on the case list saved in a run, but fresh-run creation always fills that list from the complete inventory. Internal selected-repeat support only accepts cases from an earlier run and requires unchanged case inputs and inventory; it cannot select future additions. Resume also requires the original release and cannot append cases.

A fresh subset could use the existing scheduler, agent and grader. It would need an explicit selection recorded before execution, validation against the frozen inventory, and checkpoint support for a selection without a source run. Candidates outside the inventory are not selectable; the existing admission workflow permits a provisional curation inventory after fixture and review gates for blind model validation.

Running a new subset and combining its outcomes with earlier Astra outcomes are separate decisions. The current glossary and publication contract define a published result as one completed full run. The exporter rejects selected repeats and the results-page builder requires coverage of every current case. Selection alone would therefore not produce an updated full-benchmark Astra row.

The earlier questions about manual versus automatic selection and combining historical Astra outcomes are withdrawn. The investigation above records current behavior, not an implementation plan. No new glossary term or ADR is needed.
