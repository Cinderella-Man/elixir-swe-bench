# pinchflat-pr-610: curator notes

Status: **unadmitted draft**, prepared on 2026-10-26. Nothing is pushed, imported, reviewed or qualified through `Eab.Candidates`. No model runs. These notes are curator-side only and are kept outside the bundle.

## Source

| Item | Value |
| --- | --- |
| Upstream | kieraneglin/pinchflat#610, "[Enhancement] Record and display errors related to downloading". Resolves feature request #602. AGPL-3.0. |
| Upstream merge | `e7adc9d68f40ad75819e00e26542fb3b6b24e0d1` (squash, 2025-02-12, author Kieran). Tree `49b2d3b7…`. |
| Upstream parent | `fe5c00dbeff0adcc3f35ec9639c47a8f8b3338c4`. Tree `7ea64580…`. |
| Local clone | `.local/new-cases/repos/pinchflat` (full clone of upstream, `master` at `67d8bd5`) |
| Baseline branch | `codex/pinchflat-pr-610-benchmark` = `c941ab072aa7b32381dc00b4a4965ce439e1f21f`, tree `0b9a777c…` (parent plus one neutral preparation commit) |
| Reference branch | `codex/pinchflat-pr-610-reference` = `fe38f37a15213a4f0c08405bcd2d9bd03302f1ad`, tree `2ec6f97c…` |
| Upstream replay | `70f3fb79c05e4ee3722e5c490717c06a568ddefc`. The author, date and message are upstream's. `priv/repo/erd.png` (a regenerated ERD image) is left out. `git patch-id --stable` is `e907c99d…`, equal to upstream's with erd.png excluded. Cherry-picking the merge onto the unprepared parent gives exactly the upstream tree `49b2d3b7…`. |
| Curator extension | `fe38f37a…`, parent `70f3fb79…` |
| Target fork | `https://github.com/Cinderella-Man/pinchflat`. Not created. The branches and the source-pair PR are unpublished. `provenance.json` assumes draft PR **#1**, so correct it if not. |

Later-fix window: the deep dive's audit still holds. No later upstream commit touches `last_error` handling. #640/#641 change cookie behaviour in `media_downloader.ex` and are orthogonal. Upstream never added a Failed tab or a bulk retry (`git grep` on `master`).

## What upstream changed (11 implementation paths plus a migration)

- Migration and schema: `media_items.last_error` (nullable string), castable through `MediaItem.changeset`.
- `MediaDownloader.download_for_media_item/2` wraps the old body. On `{:ok, item}` it sets `last_error: nil`. On every error it stores `StringUtils.wrap_string(message)`. Internal return shapes change to `{:error, atom, message}` and `{:recovered, item, message}`. The not-downloadable status, unknown errors and recovery failures now carry messages.
- `MediaDownloadWorker` matches the new shapes. Retry classification is unchanged at the job-state level. An unrecoverable SponsorBlock failure now goes through `action_on_error` (`{:error, :download_failed}`) instead of `{:error, :retry}`; both retry the job.
- `StringUtils.wrap_string/1`.
- UI: a `TextComponents.tooltip` component, reused by `icon_button`. The media item page gets a "Last Error" section. The source media table and history table show a red icon with a tooltip whose markup carries the reason, and the source table's `select_fields` adds `:last_error`. There are layout tweaks to the media item, source and media profile show pages.
- Tests: `media_downloader_test.exs` (return shapes, store, clear, recovered and unrecoverable) and `string_utils_test.exs`. There are no UI tests.

## Curator extension (decided design)

- `MediaQuery.has_error/0` (`last_error` not nil) and `MediaQuery.failed/0` (`has_error and not download_prevented`). These are single-purpose predicates, composed like `pending/0`.
- `Media.list_failed_media_items_for/1`.
- `DownloadingHelpers.enqueue_failed_download_tasks/1`. With `download_media: true`, it calls `MediaDownloadWorker.kickoff_with_task(item, %{force: true})` for each failed item. With `false`, it returns `:ok`. It mirrors `enqueue_pending_download_tasks/2`.
- `SourceController.retry_failed_downloads/2` uses the existing `wrap_forced_action` (flash "Retrying failed downloads.", redirect to the source). It has the route `post "/retry_failed_downloads"`.
- An Actions dropdown option "Retry Failed Downloads", `:if={@source.download_media}`, with `data-confirm`, next to Download Pending and Redownload Existing.
- A source show "Failed" tab (`id="failed"`) after Other, rendering `MediaItemTableLive` with `media_state: "failed"`. A new `generate_base_query(source, "failed")` reuses search, pagination and the upstream tooltip.
- `mix compile --warnings-as-errors --force`, `mix format --check-formatted`, `mix credo` (clean except the three naming notes on the grader-only `test/benchmark` files) and `mix sobelow --config` all pass on the reference tree. `EX_CHECK=1 mix test` passes with all tests (984).

### Product decisions written into the spec

| Question (from the shortlist risks) | Decision | Why |
| --- | --- | --- |
| What counts as a failure | Any attempted download that doesn't end downloaded. This includes not-downloadable-yet (live), unknown non-text errors, recoverable SponsorBlock (recovered or not) and never-retried errors. Skipped jobs (source not downloading, prevented, not pending, user-script veto) leave the reason unchanged. | Upstream records all of these. The skip cases follow from "only an attempt changes it". |
| Non-binary error rendering | A readable string that includes the printed term. The tests check `is_binary` plus a substring of the term, not `inspect/1` byte-for-byte. | Grilling note: do not require `inspect` exactly. |
| Readable yt-dlp message | Stored exactly as reported (equality in tests) | Upstream behaviour. It's natural and stated. |
| Pending and Failed overlap | A failed item is listed in Failed **and** keeps its Pending/Downloaded/Other membership | Keeps existing tabs unchanged. It's tested in both directions. |
| Prevented (manually ignored) items with an error | **Excluded** from Failed (they stay in Other) and not retried | Failed should equal the retry set, so every listed item is actionable. Reviewer question 1. |
| Retry semantics | A **forced** download per failed item (like the per-item Force Download), so downloaded-but-failed items (recovered, failed re-download) really are retried. Nothing is enqueued when the source doesn't download media. | A non-forced job no-ops on non-pending items, which would leave them in Failed forever. Mutant M1 shows the test discriminates. Reviewer question 2. |
| Does retry clear the error immediately? | No. It's cleared only on success, or replaced on a new failure. | Shortlist said the spec must decide. Mutant M3 is detected. |
| Duplicate retries | No second job while one is queued (the worker's existing uniqueness) | Tested by posting twice. |
| UI affordance graded | Media page: the "Last Error" heading present or absent, plus the reason text. Tables: the reason appears anywhere in the row's markup (text, tooltip or `title`). Hover is not graded. | Grilling note: no tooltip-markup equality. The raw-attributes dump already prints `last_error:`, which is why the media page check keys on the "Last Error" heading. |

### Notable observation (not changed)

At this commit, "Redownload Existing" (`kickoff_redownload_for_existing_media`) enqueues *non-forced* jobs for downloaded items. `MediaDownloadWorker` then skips them because they are not pending, so the action appears to be a no-op. This is upstream behaviour and outside the task. It is the reason the retry action is forced, and why the spec doesn't promise anything about Redownload Existing.

## Neutral preparation (`c941ab0`)

The unprepared parent run as uid 1000 at `/workspace` (the benchmark's agent user and path) gives **942 tests, 942 failures**. Every setup did `File.mkdir_p!("/config/extras")`. After moving extras under the temp directory, 17 tests still failed on hard-coded `/app/...` paths (upstream CI mounts the checkout at `/app` and runs as root). Preparation:
- `config/test.exs` gets `extras_directory: Path.join([System.tmp_dir!(), "test", "extras"])`, like the other test directories.
- `test/support/testing_helper_methods.ex` `render_metadata/1` rewrites `"/app/` to `"#{File.cwd!()}/` in the JSON fixtures.
- `source_image_parser_test.exs` (3 literals) and `command_runner_test.exs` (1 literal) use `Path.join(File.cwd!(), …)`. No assertion changes.

Result: **942 tests, 0 failures**. Format and credo are clean.

The **line-buffered reporter adapter was not added**, so the guardian structure is mirrored only where the fault applies. A probe used the upstream `media_downloader_test.exs` on the prepared baseline (12 test-phase failures) with the grader command form: 3 runs of a 4-file selection plus 2 full-suite runs (947 tests). It produced **0** dot-prefixed `EAB_` lines. Every later control, probe, mutant and seed run also had 0 (the `prefixed` count in each decode below). Pinchflat's tests are almost all synchronous (2 async files), which removes the interleaving window that Guardian's async tests had. ExUnit `max_cases` is left at its default. Reviewer question 6.

## Runtime

- Image `hexpm/elixir:1.17.0-erlang-26.2.5-debian-bookworm-20240612-slim@sha256:2d26af713ec996faa22d11bd147d5a5613a7c3c75246dbcae0c7a9aaa264ee0a`. This is exactly the builder and dev image named in the base's `docker/dev.Dockerfile` and `docker/selfhosted.Dockerfile` (Elixir 1.17.0, OTP 26.2.5). `mix.exs` requires `~> 1.17`.
- Local verification used a toolchain image built from that digest with the same toolchain lines as `Eab.Fixtures.dockerfile/4` (git, ca-certificates, build-essential and so on, user `agent` uid 1000, `mix local.hex 2.5.3`). Env: `MIX_ENV=test`, `ERL_FLAGS=+S 2:2`, `TZ=UTC`.
- SQLite through `ecto_sqlite3` 0.17.2 and `exqlite` 0.23.0, with no service. The test DB is `priv/repo/pinchflat_test.db`, which the `mix test` alias creates and migrates (`*.db` is git-ignored). The sqlean extensions are committed binaries.
- **Environment risk:** `exqlite` 0.23 has no env-var force-build switch (it uses `config :exqlite, force_build`). During `mix compile` it downloaded its checksum-pinned precompiled NIF from GitHub releases. This happens at preparation time, when docker build has network, not at test time. If preparation must avoid GitHub downloads, add `config :exqlite, force_build: true` to the fork's prep commit. The image already has build-essential.
- `mix deps.get --only test` reported Hex security advisories for historical lockfile pins. They are irrelevant offline and recorded here only.

## Hidden acceptance tests: assertion mapping

The files are `test/benchmark/download_failure_recording_test.exs` (R, DataCase), `download_failure_display_test.exs` (V, ConnCase) and `failed_downloads_test.exs` (F, ConnCase).

- yt-dlp, user scripts and HTTP are stubbed with the project's Mox mocks.
- Downloads run through `perform_job(MediaDownloadWorker, …)` in Oban's manual testing mode. There are no sleeps, timers or timing assertions.
- Failed state is set up through the specified `Media.update_media_item(item, %{last_error: …})` (silently ignored on baseline), or through real failing downloads.
- `last_error` is read with `Map.get/2`, so the baseline compiles and fails with assertions. The missing route is an explicit `Phoenix.Router.route_info/4` assertion. No new module, struct or macro is needed at compile time: the hidden files compile **warning-free** on baseline.
- Page checks parse HTML with Floki. A tab is `div[x-show="openTab === '<id>'"]` (the spec's `#tab-<id>`), and a row is the `tr` whose text contains the title.
- Successful downloads use `media_metadata.json` with the item's own `id` and `title`, to respect the `[media_id, source_id]` unique index when several items succeed.

| Test | Spec basis | Baseline | Incomplete |
| --- | --- | --- | --- |
| R a failed download records the yt-dlp error message on the media item | What counts (yt-dlp error, exact message); job still retried | fail | pass |
| R failures that are not plain yt-dlp messages still record a readable reason | Non-text error includes the printed term; not-downloadable-yet gives a non-empty message, no download call | fail | pass |
| R recoverable and non-retryable failures record the reason and keep their retry behaviour | Recovered (keeps file details), unrecoverable and never-retried rows; retried vs not unchanged: a retried job returns `{:error, _}`, a completed one `:ok` or `{:ok, _}` (`assert_completed/1`) | fail | pass |
| R a successful download clears the recorded reason | What is recorded: success sets nil (normal non-retry download) | fail | pass |
| R a new failure replaces the previous reason | Only the latest is kept | fail | pass |
| R a download job that does not attempt a download leaves the reason in place | Not failures: source not downloading, prevented | fail | pass |
| V the media item page shows the last error in its own section only when there is one | Where shown (1) | fail | pass |
| V the source page media tables show the reason on a failed item's row | Where shown (2): Pending and Downloaded rows | fail | pass |
| V the home page media history shows the reason on a failed item's row | Where shown (3): both history tabs | fail | pass |
| V a successful download removes the reason from the pages | "Once a download succeeds, none of these pages shows the old reason" | fail | pass |
| F the source page has a Failed tab listing the source's media with a recorded error | Failed tab membership, prevented and other-source exclusion, existing tabs keep membership, reason on rows | fail | **fail** |
| F the Failed tab shows Nothing Here! when no media has a recorded error | Failed tab empty state | fail | **fail** |
| F retrying failed downloads enqueues one download per failed item and keeps the errors until it runs | Retry: per-item job set, redirect, no duplicates, reasons kept, still listed | fail | **fail** |
| F retried downloads clear the error on success and replace it when they fail again | Retry is forced (a downloaded item is re-downloaded); success clears and leaves Failed; failure replaces | fail | **fail** |
| F the retry action is offered only for sources that download media | Actions link `<a href=…retry_failed_downloads>` with the label; not offered and no-op when not downloading | fail | **fail** |

Every hidden test fails on baseline in its test body (`ExUnit.AssertionError`, phase `test`). `starting_failures` equals `required`, with all 15. The five `case.json` requirement groups map every required check: record-failure-reason (3), reason-lifecycle (3), show-reason (4), failed-tab (2) and retry-failed (3). `TaskContract.read/1` accepts the contract.

Diagnostic mutants on reference plus hidden tests (not controls). These ran against the first acceptance version; revision 2 only relaxed the completed-job checks, and none of these detections depended on them:

| Mutant | Hidden result |
| --- | --- |
| M1 retry enqueues non-forced jobs | fails only "retried downloads clear the error…" (the downloaded item is not re-downloaded) |
| M2 Failed tab and retry include prevented items | fails the Failed tab test and both retry-run tests |
| M3 retry clears `last_error` at enqueue time | fails "retrying failed downloads … keeps the errors until it runs" |
| M4 success path never clears `last_error` | fails R clear, V removes-from-pages, F retried-clear |

Alternative implementations that the tests deliberately accept include: the reason as visible text, tooltip markup or a `title` attribute; any wording for the not-downloadable message; any readable rendering of non-text errors that contains the term; a separate LiveView or component for the Failed tab, as long as it sits in the `failed` tab; and any internal downloader return shapes. At the job boundary, the tests require only `{:error, _}` for a retried job, and accept `:ok` or `{:ok, _}` for a completed one (`assert_completed/1`, revision 2). Before revision 2, they required `{:ok, _}` or `:ok` exactly at six sites, which wrongly rejected a reference variant whose worker returns `:ok` instead of `{:ok, :non_retry}`.

## Preservation

`grading.preservation` lists these files (239 tests):
- `media_download_worker_test`
- `downloading_helpers_test`
- `media_quality_upgrade_worker_test`
- `media_test`
- `string_utils_test`
- `media_item_controller_test`
- `media_profile_controller_test`
- `page_controller_test`
- `source_controller_test`
- `sources/media_item_table_live_test`

They pass on baseline and on the reference (regression phase). **`media_downloader_test.exs` is excluded.** Its baseline version asserts the downloader's old internal return shapes, and 7 of its tests fail against the upstream implementation. All 942 baseline tests were run against `reference.patch`, and only that file fails. The spec says those internal return values may change. Downloader behaviour that matters is covered through the worker in the hidden R tests, and by the worker preservation file.

## Verification log (2026-10-26)

Every container used the pinned image's toolchain build with `--cpus=2 --memory=6g --user 1000:1000 --rm`, one at a time. Dependencies were fetched once, with network, by `mix deps.get --only test && mix deps.clean --unused && mix compile` (seed `deps/` and `_build/`). Every test run used `--network none`.

- Grader-flow runs used `elixir -r /opt/eab-grade/formatter.exs -S mix test … --seed 0 --formatter ExUnit.CLIFormatter --formatter ElixirAgentBenchmark.TrustedFormatter`, with `priv/fixtures/grade_formatter.exs` mounted read-only.
- Scripts are in the session scratchpad `pinchflat-610/scripts/`: `run.sh`, `mkws.sh`, `control.sh`, `decode.py`, `check_controls.py` and `contract_check.exs`. Logs are in `pinchflat-610/logs/`.
- No durations were recorded or interpreted.

Full suites:

| Tree | Result |
| --- | --- |
| Upstream parent `fe5c00d`, unprepared, uid 1000 | 942 tests, 942 failures (`/config/extras`) |
| Same, extras moved only | 942 tests, 17 failures (`/app` paths) |
| Prepared baseline `c941ab0` | 942 tests, 0 failures, rc 0 |
| Reference branch `fe38f37` (upstream tests) | 949 tests, 0 failures, rc 0 |
| Baseline + `reference.patch` + `reference-tests.patch` | 969 tests, 0 failures, rc 0 |
| Same + `acceptance.patch`, `EX_CHECK=1` (test warnings as errors) | 984 tests, 0 failures |
| Baseline tests against `reference.patch` | 942 tests, 7 failures, all in `media_downloader_test.exs` (preservation exclusion above) |

Grader-flow controls (`control.sh`) repeat `Grader.do_grade/5`:
1. Apply the patch and `git add -A`.
2. Run submission: preservation plus the changed `_test.exs` files.
3. Restore `test/`, apply the acceptance overlay and run hidden.
4. Restore `test/` and run regression.

| Control | Submission | Hidden (15) | Regression |
| --- | --- | --- | --- |
| Unchanged | 239/239 pass | 0 pass, 15 fail, all phase `test` (AssertionError); the set equals `starting_failures` exactly | 239/239 pass |
| Reference + reference-tests | 290/290 pass (8 changed test files) | 15/15 pass | 239/239 pass |
| Incomplete (upstream implementation only) | 239/239 pass | 10 pass, 5 fail (all F tests), all phase `test`, all in `starting_failures` | 239/239 pass |
| Reference + reference-tests + integrity | no tests (compile-time `System.halt(0)`), not completed | not completed | not completed |

- `check_controls.py` replays `valid_controls?` on these outcomes, and every condition holds.
- The coverage probe applied `reference-tests.patch` only, on the baseline, and ran the 8 changed files. It completed with 233 tests and rc 2. 30 tests failed, all in phase `test`, and every one passed in the reference submission.
- Determinism: hidden tests on the reference at seeds 0, 1, 2 and 3 all gave 15/15. Every control, probe, mutant and seed log had 0 prefixed `EAB_` marker lines. Logs are at most 131 KB, well under the grader's 2 MB limit.
- Source reconstruction: the baseline export gives tree `0b9a777c…`. `git apply --index` of `reference.patch` and `upstream-tests.patch` then gives `2ec6f97c…`, which equals the reference branch tree. `upstream-tests.patch` is byte-identical to upstream's own test diff (`e7adc9d6~1..e7adc9d6 -- test`). `incomplete.patch` is byte-identical to upstream's implementation diff excluding erd.png.
- `contract_check.exs` loads the repository's own `task_contract.ex`, `provenance.ex` and `grader.ex` in the pinned image, using Jason from the build.
  - `TaskContract.read/1` succeeds with 15 required and 15 starting failures. `Provenance.validate!/2` returns `:ok`.
  - `validate_patch` returns `{:ok, []}` for the three test patches against `test/`, and for `reference.patch`, `incomplete.patch` and `integrity.patch` against `allowed_edit_prefixes`.
  - The appended solver instructions were printed and reviewed.

`integrity.patch` is a byte copy of `.local/fork-migration/drafts/operately-pr-1069/integrity.patch` (sha256 `9345cf52…d193`).

## Revision 2 (2026-10-26, independent reviewer's blocking fixes)

1. **Over-strict completed-job checks.** The spec allows internal return values to change as long as the job's outcome stays the same. Yet the hidden tests required exactly `{:ok, _}` (the live-stream and Video unavailable items) or exactly `:ok` (four sites). Both test files now use a private `assert_completed/1`, which accepts `:ok` or `{:ok, _}`, the two values that complete an Oban job. It replaces the matches at `download_failure_recording_test.exs` lines 50, 90, 100, 131 and 137, and at `download_failure_display_test.exs` line 98 (`acceptance.patch` lines 203, 243, 253, 284, 290 and 104 before the change). The `{:error, _}` checks are unchanged. Test names, `required` and `starting_failures` are unchanged.
2. **Grading wording in the spec.** `ticket.md` line 31 used to end "Tests put items into the failed state this way." It now reads "… accept `last_error`, like the other system-controlled attributes, so a reason can be set or cleared directly."

Reruns use the same bounds as before: pinned toolchain, `--cpus=2 --memory=6g`, uid 1000, one container at a time, `--network none` and seed 0. No timing was recorded. Revision 1 logs are kept in `logs/v1/`.

| Run | Result |
| --- | --- |
| Unchanged control | submission 239/239; hidden 0/15, all 15 `test`-phase AssertionErrors, equal to `starting_failures`; regression 239/239 |
| Reference control | submission 290/290; hidden 15/15; regression 239/239 |
| Incomplete control | submission 239/239; hidden 10/15, the 5 F tests fail in `test` phase; regression 239/239 |
| Integrity control | halts at compile, not completed |
| `check_controls.py` (`valid_controls?` replay) | all conditions hold |
| Reference branch full suite | 949 tests, 0 failures, rc 0 |
| Reference + reference-tests + acceptance, `EX_CHECK=1`, `mix format --check-formatted` | 984 tests, 0 failures, rc 0; format rc 0 |
| `:ok` variant (reference worker returns `:ok` instead of `{:ok, :non_retry}` at both sites) with revision 2 hidden tests | 15/15 pass; `media_download_worker_test.exs` 35/35 |
| Same variant with revision 1 hidden tests (reproducing the reviewer's finding) | 13/15; fails "failures that are not plain yt-dlp messages…" and "recoverable and non-retryable failures…" |

Every revision 2 log has 0 dot-prefixed `EAB_` lines.

## Bundle hashes (sha256, revision 2)

```
5a36f0171f59a45bfbdcb70de3466bf2e88849d669a8a0671bdd48ca7ca7bdb7  acceptance.patch
73c81670f9b5093761b585822ef65588fc34c80e453c2b41fb90c785c502ddf0  case.json
82da358ac98ccaa0abe1113098441e6b7c9d2e724762bb8958cd2b59e2471bee  incomplete.patch
9345cf52f8dccb1cf508da8776f27ce7317661503c16dd2710d053c7416dd193  integrity.patch
9c20a77bc10bc571e467a45e69601bf0378cb5fbec33b025a8c27ed50f7e511b  provenance.json
1de38cc082a7935e28a8980a79028575a18f43bce51d741d918d741ee23e0053  reference.patch
1530e6f0b190e676234156db6a97a498ca1b9fd85211c33c0326949f04a9dc85  reference-tests.patch
5eccc3b4cba1896976f81f1e82e551b3a7edc9c18ae99fac713b6e48b42742d7  ticket.md
044075192196c7fc484f5556973d93251559ece4363abb1169f02ac617b219b2  upstream-tests.patch
```

There is no `upstream-docs.patch`: the PR changes no Markdown or text files.

## Remaining gates

1. Create the fork centrally, push both branches, open the draft source-pair PR, and fix the `pull_request` number if it is not #1.
2. Import through `Eab.Candidates`, get an independent requirements-first review, and run three fresh qualification rounds. This includes the first preparation that uses SQLite in the runner; check that the `exqlite` NIF builds in the prepared image.
3. Run two Opus 5.5 xhigh validations (ADR 0012/0013).

## Open questions for the reviewer

1. The Failed tab and retry **exclude download-prevented items**, which stay under Other even with a recorded error. The alternative is to list them but not retry them.
2. Retry is a **forced** download, which bypasses the pending check and overwrites files, and it is a no-op for sources with `download_media: false`. Should it also work for non-downloading sources, as the per-item Force Download does?
3. "Not downloadable yet" (live streams) counts as a failure, as in upstream, so such items show under Failed until downloaded.
4. `media_downloader_test.exs` is left out of preservation because upstream changed internal return shapes. The spec permits that.
5. The preparation commit edits two existing test files and a test helper (path resolution only). That is neutral, but it does touch `test/`.
6. There is no line-buffered reporter adapter, because the fault did not reproduce. Add it anyway for uniformity with Guardian and Ash?
7. `allowed_edit_prefixes` adds `priv/repo/migrations/` (needed) and `assets/` (UI styling). `config/` and `mix.exs` are not allowed.
8. The Redownload Existing no-op observation is not addressed. It is upstream behaviour and outside the task.
9. The `exqlite` precompiled NIF is fetched from GitHub at preparation time. Should the fork force a source build instead?
