# Case freeze audit — 2026-10-26

Read-only review of the fourteen active cases before freezing them for three-run series ([ADR 0011](../adr/0011-publish-three-run-series.md)). After the freeze, any change to a case's files makes every published series stale, so this audit looks for anything that would force such a change later or make an outcome vary for reasons other than the model. Nothing was built, qualified or run; findings come from the bundles, committed evidence, saved grades and the benchmark source. Decisions and the executed freeze are recorded separately.

## Per-case results

| Case | Evidence on record | Content | Before freezing |
| --- | --- | --- | --- |
| plausible-pr-5939 | 3 rounds (2026-10-15), 2 reviewed Astra passes | Sound | Pin images by digest; fresh rounds |
| plausible-pr-5956 | 3 rounds (2026-10-15), 2 reviewed Astra passes | A required check races an asynchronous cache write | Pin images; poll the post-write reads; fresh rounds |
| plausible-pr-6449 | 3 rounds (2026-10-15), 2 reviewed Astra passes | Sound; the clarified ticket settles the old invalid-input concern | Pin images; fresh rounds |
| livebook-pr-2219 | 3 rounds (2026-10-15), 2 reviewed Astra passes | Sound | Fresh rounds |
| livebook-pr-2527 | 3 rounds (2026-10-15), 2 reviewed Astra passes | A required check imposes an unstated whitespace rule | Decide the whitespace rule; fresh rounds |
| livebook-pr-2663 | 3 rounds (2026-10-15), 2 reviewed Astra passes | Sound | Fresh rounds |
| livebook-pr-2800 | 3 rounds (2026-10-15), 2 reviewed Astra passes | Sound | Fresh rounds |
| livebook-pr-2822 | 3 rounds (2026-10-15), 2 reviewed Astra passes | Sound | Fresh rounds |
| livebook-pr-3076 | 3 rounds (2026-10-15), 2 reviewed Astra passes | Sound | Fresh rounds |
| accent-pr-183 | Valid admission, 3 current rounds, 2 reviewed Astra passes | Sound | — |
| livebeats-pr-37 | Valid admission, 3 current rounds, 2 reviewed Astra passes | Browser checks wait only 5 s before a hard assertion | Widen the waits; fresh rounds |
| ash-pr-3031 | Valid admission, 3 current rounds, 1 reviewed Astra pass (user override) | Sound | — |
| operately-pr-1069 | Valid admission, 3 current rounds, 2 reviewed Astra passes | Sound | — |
| operately-pr-1205 | Valid admission, 3 current rounds, 2 reviewed Astra passes | Sound | — |

Every bundle's current file hashes equal its recorded evidence. The nine legacy cases are byte-identical to the [2026-10-15 freeze](case-freeze-2026-10-15.md), but their rounds are bound to qualification identity `9eaef656…`; the current identity is `da5bcd94…` because `lib/eab/inventory.ex` gained case-folder discovery. That change does not alter grading, but the freeze needs fresh rounds under the current identity and runtime images.

## Findings that need a decision

- **Fork source (13 cases).** Only Ash pins a prepared branch in the user's fork, as [AGENTS.md](../../AGENTS.md) requires. The others pin upstream commits and trees; Accent, LiveBeats and both Operately cases also apply `environment.patch` overlays. The fork migration was deferred ([prepared-forks audit](../../verification/prepared-forks-2026-10-20/README.md)); fork branches already exist at the identical commits for the Plausible and Livebook cases. Migrating rewrites `case.json` and `provenance.json`, so it happens before the freeze or not until the next planned release.
- **Plausible image pins.** The three Plausible manifests name runtime, Node and service images by tag (`postgres:16-alpine` and `postgres:18-alpine` float). Every other case pins `@sha256`. Runs on other machines could resolve different images under the same release. The qualified digests are recorded in [the 2026-10-15 evidence](../../verification/frozen-cases-2026-10-15/evidence.json).
- **Plausible 5956 race.** `AuditTrackerUpdateTest` requests `/js/<id>.js` immediately after each create and update (`acceptance.patch:99-105`). The starting code writes through `broadcast_put`, and the reference's CE path writes synchronously, so it passes deterministically; the common one-line fix keeps the asynchronous write and passes only when the write wins. Upstream's own tests wait with `eventually`. Polling those reads with the existing helper only widens acceptance; unchanged code and the incomplete control still fail.
- **Livebook 2527 whitespace rule.** A required check expects `"\n \t\n"` between the signed content and the stamp to still verify without warnings (`acceptance.patch:59-61`). The ticket does not say so, and a secure repair that verifies every byte before the stamp would fail.
- **LiveBeats 37 waits.** Three checks wait 5 s for the title or media metadata and then assert (`acceptance.patch:14,24,49`); the browser default is 10 s (`environment.patch:117`). Real runs grade while the next attempt runs and preparation proceeds, boxes are capped at two CPUs, and contributors run on other hardware. A slow host would score a correct submission as a model failure.

## Findings recorded without a change

- **Livebook 2219 flip.** Gyro-S TQ1_0 failed one run and passed another. Its repair passed all 86 hidden and 83 preservation checks; it failed its own added test, which renders once after an asynchronous frame update where the repository's tests render twice. The case requires model-written tests to pass, so this is model variance.
- **Livebook 2822 failures.** All three local-model failures fail the same two checks in test bodies. Two leaked a failed cell's process-dictionary changes into later evaluations. One kept bindings in the failed evaluation's stored context, which Livebook's own upstream test rejects. The case is kept as is.
- **Plausible 5956 cache injection.** `TrackerCacheTest` seeds scripts through `Adapter.put_many(:tracker_script_cache, …)`, tying the check to the cache's name. Every observed solution keeps it; accepted as a low risk.
- **Solver-visible text left unchanged.** Ash's clarification mentions this shared machine's timing rule, and LiveBeats does not say that only `.mjs` tests under `test/` count as the regression test. Changing either needs new blind runs; both are harmless.
- **Livebook 2800, 2822 and 3076** rely on visible starting behavior plus "preserve existing behavior" for details the shortened tickets no longer state (source line in errors, rollback of failed state, validation messages). Each is defensible.
- **Grading timeouts.** A suite exceeding `test_timeout` is graded as a failure, not an infrastructure error, so very slow hardware can lower a score.

## Decisions

The user chose to rebuild instead of freezing ([ADR 0012](../adr/0012-rebuild-release-and-validate-with-unpublished-opus-runs.md)):

- All fourteen cases move to prepared fork branches with no overlays, digest-pinned images and the schema-v2 contract. Every scored check becomes a stated requirement, which also covers the Livebook 2800, 2822 and 3076 details above.
- Plausible 5956 polls its post-write reads with `eventually`.
- Livebook 2527 keeps its whitespace check and states the rule, because the upstream fix deliberately trims whitespace after the signed content (`reference.patch:33`).
- LiveBeats 37 waits 30 s instead of 5 s and 10 s, and states that its regression test is an `.mjs` file under `test/`.
- Ash 3031 drops the machine-specific timing text from its clarification.
- The admission receipt keeps its qualification hash as history only.
- The toolchain recipe pins Hex 2.5.3; existing images had drifted between 2.5.2 and 2.5.3. Rebar3 stays with Mix's per-Elixir selection, and system packages stay unpinned until snapshot mirrors are worth their cost.
- Old runs and records were deleted on 2026-10-26.
- Opus 5.5 validates every case twice through the Claude Code harness before about six cases are added and any series runs.

## Benchmark code (no case change)

- Starting a run requires every schema-v2 `admission.json` to record the current qualification hash (`Eab.Candidates.validate_evidence!`), which covers grader files and `mix.lock`. A dependency bump would therefore force admission re-exports, changing case files and making every series stale. ADR 0011 requires decoupling this.
- The toolchain recipe installs unpinned apt packages and runs `mix local.hex/rebar --force` (`lib/eab/fixtures.ex`). Accent already broke once on a newer Hex. Contributors rebuild these images on their own machines.
- Published results carry per-case `attempt_ms`, which [AGENTS.md](../../AGENTS.md) says is not valid performance evidence from this machine.
- [docs/evaluation.md](../evaluation.md) still says eleven cases, and three documents still describe the resolved Plausible 6449 ambiguity as open.
