# plausible-pr-5956 — schema-v2 conversion notes (curator only, not part of the bundle)

Author: case-author agent, 2026-10-26. Nothing was run: no Docker, mix, tests or qualification.

## Files changed in the bundle

- `case.json`: schema v2, `task_kind: bug_fix`, `suite` renamed to `project`, legacy contract keys removed, `grading` added, images pinned by digest.
- `acceptance.patch`: `AuditTrackerUpdateTest` now polls each post-write read with `eventually/3`. The hunk header changed from `+1,47` to `+1,66`. `git apply --check` succeeds in an empty repository; both files are new.
- `incomplete.patch`: new; byte-identical to the legacy partial (`replace`, 2 occurrences).
- `integrity.patch`: new; the legacy halt patch text.
- Unchanged: `repository`, `provenance.json`, `reference.patch`, `reference-tests.patch`, `upstream-*.patch`, `ticket.md`, clarifications (no host-specific text).
- `reference-tests.patch` is no longer identical to `acceptance.patch`. It keeps the unpolled reads. That is fine: it is the reference's "model test", the reference writes synchronously, and on the starting source it still fails in the test body (see below).

## Image pins (2026-10-15 evidence.json)

Same as 5939:

- `hexpm/elixir:1.19.4-erlang-27.3.4.6-alpine-3.22.2@sha256:c129490f…`
- `node:23.2.0-alpine@sha256:ecefaffd…`
- `postgres:16-alpine@sha256:721873c3…`
- `clickhouse/clickhouse-server:24.12.2.29-alpine@sha256:e5e232b4…`

## Starting failures (empty_patch.hidden, phase `test`), unchanged by the polling

1. `AuditTrackerUpdateTest::test dedicated scripts follow successful writes without an external cache refresh`
2. `TrackerCacheTest::test dedicated delivery follows repeated configuration changes and isolates sites`

Both were already `required`. `required` has 3 checks: these two plus `unknown dedicated tracker remains a 404`.

## The race fix

`assert_script/5` first calls `eventually(fn -> {serves_script?(…), :ok} end, 20, 50)`. The predicate GETs `/js/<id>.js` and is true only for a 200 response containing `window.plausible`, the domain and the expected `fileDownloads`/`outboundLinks` flags. After polling, the original assertions run verbatim on a fresh response, including `response(200)` and the Node syntax check. A failure therefore shows the same messages as before, with the actual served content, not a "nil" from `eventually`.

**Bound.** At the baseline, `eventually/3` sleeps `wait_time_ms * attempt` after every miss, including the last one, so the delay grows linearly.

- The suggested "100 ms × 50" taken literally, as `eventually(…, 100, 50)`, sleeps up to 100 × 1275 ms = 127.5 s.
- That exceeds ExUnit's default 60 s per-test timeout. Plausible's `test_helper.exs` does not change it, and the grader adds no `--timeout`.
- A permanently stale submission would then end with `ExUnit.TimeoutError` instead of an assertion message.
- I kept 50 attempts and used a 20 ms base: at most 25.5 s per read, well below 60 s. That is still orders of magnitude above a local `Task` + `:rpc.multicall` ETS write.
- **Reviewer decision:** keep (20, 50), or use (100, 50) with `@moduletag timeout: 180_000`.

**What polling tolerates.** A repair that keeps the asynchronous `broadcast_put` (typically just removing `:bag`) has only two transient states before its write lands:

- a cache miss, which returns `nil` and so a 404;
- the previous value, which is a 200 with stale flags.

The predicate retries both. Raised errors are deliberately not rescued, so they fail at once. Polling cannot hide a stale write either. Each read waits for its own write, and the next update starts only after that write is observed. So no earlier write can land after a later one in this test.

### Unchanged code still fails permanently

Traced at baseline `10b11697…`.

1. The tracker cache is started with `ets_options: [:bag, read_concurrency: true]` (`application.ex:163-176`), and writes go through `broadcast_put`, which runs `Task.start` → `:rpc.multicall(Adapter, :put, …)` → `ConCache.dirty_put`.
2. **Create.** One `{id, script}` object. The first poll may see a miss (404), then the script, so the initial reads pass.
3. **First update** (`file_downloads: true`). Its asynchronous put adds a *second* object under the same key; a bag only rejects identical objects. Until it lands, reads see the stale value and the test keeps polling. Once it lands:
   - `ConCache.Operations.fetch/3` returns `{:ok, [old, new]}` for several objects;
   - `Tracker.get_plausible_main_script/2` returns a list;
   - `TrackerPlug.request_tracker_script/2` matches only `is_binary` or `nil`, so it raises `CaseClauseError`;
   - the error propagates through `Phoenix.ConnTest` into the test body, which fails in phase `test`.
4. **Why it stays broken.** Nothing deletes the key during the test; `on_exit` runs afterwards. Later writes add no new objects (`false` is already present). `ttl_check_interval` is `false`. The warmers return `:ignore`, because `config/test.exs` has `Plausible.Cache, enabled: false` at boot and `Warmer.init_cycle/1` returns `:ignore` unless the cache is enabled or `force_start?` is set. So no periodic refresh runs. The audit agrees on this.

### The `:bag` incomplete control still fails permanently

The reference's CE path writes synchronously (`Plausible.Site.TrackerScriptCache.put` → `Adapter.put`). The incomplete control puts `:bag` back on both reference caches.

- After the first update the bag holds two objects for the ID at once.
- The very first poll attempt raises the same `CaseClauseError`, and the state is permanent for the same reasons as above.
- `TrackerCacheTest` is untouched and fails as before, because its `put_many` adds a second object to the bag.

So the qualified failure set and phases should be unchanged: the empty patch fails starting failures 1 and 2, and the incomplete control fails both. This rests on source tracing only; nothing was executed.

**Caveat about ConCache.** I read the multi-object `fetch/3` behavior from a local con_cache 1.1.1 checkout (`/home/bat/projects/credence/corpus/con_cache`). The lock pins the aerosol fork at `d050e133`, which I did not inspect. Suppose that fork instead treats several objects as a miss. Then the read would be a permanent 404, the poll would run out after 25.5 s, and `response(200)` would fail in the test body. It is still a permanent behavioral failure, just slower.

### The reference passes deterministically

The CE write is synchronous on a `:set` table, so the first poll attempt succeeds and the added cost is one extra GET per read.

## Assertion mapping

| Requirement | Check | Why |
| --- | --- | --- |
| `scripts-follow-writes` | AuditTrackerUpdateTest | The test enables `Plausible.Cache`, as in production CE. The text therefore says "application cache enabled", which the ticket leaves implicit, and spells out create → serve, repeated updates, valid JavaScript, own domain and other-site isolation. It gives no timing promise; the check tolerates a short delay. |
| `cache-refresh-keeps-scripts-current` | TrackerCacheTest repeated changes | The test seeds through `Adapter.put_many(:tracker_script_cache, …)`, an accepted low risk left as is. The text discloses that the existing `:tracker_script_cache` and its refresh must keep serving current, site-specific scripts. This is a preservation constraint, not a fix. |
| `unknown-tracker-not-found` | unknown ID → 404 | Existing behavior. |

## incomplete.patch verification

The probe has `before: "+              ets_options: [read_concurrency: true]"` and `occurrences: 2`. The split-count is 2, so it is replaced with `[:bag, read_concurrency: true]`. `diff reference.patch incomplete.patch` shows exactly those two lines (84 and 100). sha256 `f256efb8ffbb93825718d4d5a08f5eeeb1c7b186f32a1cf2b4d6d33ac97b809e`, 13102 bytes.

## Residual risk (unchanged, outside this brief)

`TrackerCacheTest` still reads right after `put_many`. A repair that keeps the asynchronous put could, in theory, have an *earlier* write's task land after the test's synchronous `put_many` of a newer value. That task would have to stall across a full update transaction, a DB refresh and a GET, so it is very unlikely. It was left as is under the brief's instruction not to touch `TrackerCacheTest`.
