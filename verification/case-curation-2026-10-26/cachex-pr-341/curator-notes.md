# cachex-pr-341 curator notes (draft, unadmitted)

Curator-side record for the draft bundle in `cachex-pr-341/`. Not solver input. Status: **provisional draft**: locally verified, not imported, not reviewed, not qualified through `Eab.Candidates`, no model runs. Nothing has been pushed; the fork `https://github.com/Cinderella-Man/cachex` does not exist yet.

## Source investigation

Upstream: `whitfin/cachex`, MIT. Shortlist §3 (`docs/research/feature-case-shortlist-2026-10-26.md`), deep dive `docs/research/new-candidates-2026-10-19/large-features/deep-dive/deep-dive-cachex-341.md`.

| Item | Value |
| --- | --- |
| #341 "Allow warmers to be have named processes" (fixes #334) | landed as three linear commits `3a0d7a9` → `9a16ca4` → `e700e966` on 2024-03-24 (PR head `3f62838`); parent of the first is `b22cb1ff` |
| #342 "Add a new :wait option to control Cachex.warm/2" (fixes #336) | merge `4a87f337`, single parent `e700e966` (adjacent interval, no synthetic tree) |
| Upstream pair | broken `b22cb1ff` (tree `7f57d4d5`), fixed `4a87f337` (tree `f8d7eddd`) |
| Upstream size | #341: 8 impl + 2 test files; #342: `cachex.ex`, `actions/warm.ex`, `warm_test.exs`. No Markdown/docs files changed, so no `upstream-docs.patch` |
| Toolchain | CI matrix tops out at `elixir:1.16` (Elixir 1.16.2 / OTP 26.2.3 in March 2024). `mix.exs` declares `~> 1.5`. `mix.lock` is git-ignored upstream |

What the upstream change actually does (read from the diffs, then confirmed by running the hidden tests against the upstream-only replay):

1. Adds `name` to the `warmer` record; the validator accepts `nil`, atoms or pids. Named warmers are started with `name:`; **unnamed warmers are no longer registered under their module** (they become anonymous and are linked to their pid by the new `Services.link/1`). This makes one unnamed module usable by several caches.
2. Keeps the Incubator child id as **the module**, so two warmers built from one module still collide (`{:duplicate_child_name, Module}`). The use case in #334 ("the same warmer to pull from two different sources") therefore still fails at the merge commit. Current upstream `main` still has `id: module`.
3. Renames `warm/2`'s `:modules` option to `:only` (`:modules` is silently ignored afterwards, so it warms everything) and returns the linked `name` of each warmer: the name for named warmers, an **anonymous pid** for unnamed ones (the baseline returned modules).
4. #342 adds `wait:` using `Task.async` + `Task.yield_many/1` with the **default 5 s timeout**; a slower warmer makes `extract_name/1` crash. Startup warming is routed through `warm/2` with `notify: false`, so a slow `async: false` warmer also crashes cache start (baseline used `GenServer.call(..., :infinity)`). Upstream fixed this a year later in #403 (`688837f`); that commit is not replayed.

Later upstream history (#343 async-flag rename, v4 API churn) is out of scope.

## Branches (local clone `.local/new-cases/repos/cachex`, not pushed)

| Branch | Commits (oldest first) |
| --- | --- |
| `codex/cachex-pr-341-benchmark` | `b22cb1ff` (upstream) → `d80c9639` preparation (tree `f2a8492b`) |
| `codex/cachex-pr-341-reference` | `d80c9639` → `e11915e4` (=3a0d7a9) → `6d33d281` (=9a16ca4) → `34348f65` (=e700e966) → `1b07f492` (=4a87f337, tree `bb8a78cd`) → `9ee7ca31` curator extension (tree `d202bc7f`) |

Replayed commits keep Isaac Whitfield's authorship and dates; committer is the curator. Each replayed commit differs from its upstream original only in `.gitignore` and `mix.lock` (checked with `git diff --stat <upstream> <replay>`: 2 files).

### Preparation commit `d80c9639` (neutral)

- Adds a test-environment `mix.lock` (eternal 1.2.2, jumper 1.0.2, unsafe 1.0.2, local_cluster 1.2.1, global_flags 1.0.0, **sleeplocks 1.1.2**: the release current in March 2024; resolving today gives 1.1.4 from 2026-04) and removes `mix.lock` from `.gitignore`.
- Changes `.gitignore` `/benchmarks` → `/benchmarks/*`. Upstream tracks `benchmarks/main.exs` but its `!/benchmarks/main.exs` exception never took effect, so the fixture's `git add .` would drop that tracked file and the runtime index would not match the pinned tree. With the fix, a fresh `git init && git add .` of the exported tree plus `deps/` and `_build/` gives tree `f2a8492b`, identical to the pinned baseline.
- No library or test code changes. No `environment.patch`.

### Curator extension `9ee7ca31`

Author Kamil Skowron (curator), message starts "Curator extension for the elixir-agent-benchmark case cachex-pr-341; not part of upstream". Six lib files, no tests (keeps `upstream-tests.patch` exact):

- `services/incubator.ex`: child id `name || module`, so named warmers sharing a module coexist (completes #334).
- `options.ex`: reject duplicate identities (`name || module`) with `:invalid_warmer` before anything starts.
- `spec/validator.ex`: names must be atoms (a pid cannot be registered as a name, and the spec says atoms).
- `actions/warm.ex`: `:modules` alias of `:only` (`:only` wins); report unnamed warmers by module (`is_pid(name)` after linking means unnamed); `Task.yield_many(:infinity)`.
- `cachex.ex`, `spec.ex`: documentation of names, module selection and result order.

Why this shape: it makes the feature do what its own issue asks (several warmers from one module), keeps every existing caller's results unchanged (the full baseline suite of 200 tests passes against the reference library), and removes the 5 s regression for the newly specified "no timeout" wait. `mix format --check-formatted` passes and the project compiles without warnings on the reference.

## Spec decisions (grilled outcomes, recorded in `ticket.md`)

| Question | Decision |
| --- | --- |
| Name domain | atom or `nil`; strings, integers, lists and `{:global,…}`/`{:via,…}` tuples rejected with `{:error, :invalid_warmer}` (deep dive's must-fix #1) |
| Unnamed warmers | not registered under the module any more (explicit behaviour change, follows upstream); reported by module in results (compatibility) |
| One module, several warmers | allowed with distinct names (extension) |
| Duplicates | identity = name, else module; duplicate identities rejected at start with `:invalid_warmer` |
| `only:` with a module whose instances are named | the module selects every warmer built from it, named or not (shortlist ambiguity #1) |
| Return value | `{:ok, [atom]}`, one entry per triggered warmer, configuration order; name for named, module for unnamed (shortlist ambiguity #2) |
| `wait:` | default false; true returns after every selected warmer finished and wrote values; no timeout |
| `modules:` | kept as alias of `only:`; `only:` wins when both are given |
| Startup, periodic warming, hooks | unchanged; startup still emits no `:warm` hook notification |
| Non-goals | runtime add/remove, global/via names, timeout option, reporting warmer output/errors, async flag rename (#343), distribution, hook naming |

## Hidden acceptance tests (`test/benchmark/named_warmers_test.exs`)

All tests build warmer specs through `Cachex.Spec.warmer/1` at runtime (`Code.eval_quoted`) after a named assertion that the record accepts `:name`, because the record macro rejects unknown keys at compile time and the file must compile on the baseline. Caches are started from a task that traps exits and captures crashes, so a failed start is an assertion failure, not an exit of the test process. No sleeps; synchronisation is via a gate `Agent`, messages from the warmer, `Task.yield/2`, and `:sys.get_state/1`.

| # | Test | Requirement | Spec source | Baseline | Upstream only | Reference |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | a named warmer is registered under its name and warms the cache at startup | named-warmers | Warmer names | fail (no `:name` key) | pass | pass |
| 2 | warmers built from one module run side by side under distinct names | named-warmers | Warmer names | fail | **fail** (duplicate child id) | pass |
| 3 | an unnamed warmer module can serve several caches at once | named-warmers | Warmer names | fail (`already_started`) | pass | pass |
| 4 | warmer names other than atoms are rejected and nil means unnamed | warmer-validation | Identity and validation | fail | pass | pass |
| 5 | warmers sharing an identity within one cache are rejected | warmer-validation | Identity and validation | fail | **fail** (supervisor crash) | pass |
| 6 | only warms the warmers matching a listed name or module | selective-warming | Selecting; Return value | fail | pass | pass |
| 7 | a module entry selects every warmer built from that module | selective-warming | Selecting; Return value | fail | **fail** (duplicate child id) | pass |
| 8 | waiting warm returns only after the selected warmers have finished | waiting | Waiting | fail | pass | pass |
| 9 | warming without wait returns before the warmers have finished | waiting | Waiting (default) | pass | pass | pass |
| 10 | unnamed warmers are reported by module and the modules option still selects them | compatibility | Compatibility | pass | **fail** (pids; `:modules` ignored) | pass |

Starting failures: tests 1–8 (all fail in the test body with `ExUnit.AssertionError`). Required: 1–10. Tests 9 and 10 are positive preservation checks for the default and for existing callers.

Timing notes (no duration is asserted or recorded):
- Test 8 asserts `Task.yield(task, 250) == nil` while the warmer is provably blocked at its gate. A waiting implementation can never return there, so the reference path is deterministic; the window only bounds how long a non-waiting implementation is observed.
- Test 9's `Task.yield(task, 5_000)` and the `assert_receive …, 5_000` calls are watchdogs; a correct implementation returns immediately.

Discrimination checks run locally:
- Mutation "`wait:` ignored" → only test 8 fails. Mutation "`wait:` defaults to true" → only test 9 fails.
- Alternative implementation written independently of the reference (name field placed first in the record, child ids `{:warmer, module, name}`, pids resolved at call time instead of linking, sequential `GenServer.call` for waiting, different duplicate check) → all 10 acceptance tests and the 57 preservation tests pass. The tests do not depend on the record layout, child ids, `Task` use or linking.

## Preservation

`mix test test/cachex/actions/warm_test.exs test/cachex/warmer_test.exs test/cachex/options_test.exs test/cachex/spec/validator_test.exs test/cachex/hook_test.exs test/cachex/services/informant_test.exs test/cachex/services/steward_test.exs test/cachex/services_test.exs test/cachex/stats_test.exs test/cachex_test.exs` (57 tests). Covers manual warming with `:modules` and module results (baseline `warm_test.exs`), startup/async/state/hook-from-warmer behaviour, warmer option parsing and validation, hook linking (moved into `Services.link/1` by #341), Steward provisioning and stats hooks. Passes on baseline and reference; the upstream-only control fails the two baseline `warm_test.exs` tests.

## Reference tests (`reference-tests.patch`)

Upstream's own test changes use `warmer(…, name: …)` at compile time, so they cannot compile on the baseline and would make the coverage probe incomplete. `upstream-tests.patch` keeps them exactly (it reconstructs the fixed tree); `reference-tests.patch` holds curator tests in project style instead: two tests in `test/cachex/actions/warm_test.exs` (waiting; `only:` by module/name with a shared module), three in `test/cachex/warmer_test.exs` (one module under two names; one unnamed module in two caches; invalid and duplicate names), and a `Helper.create_named_warmer/3` runtime builder in `test/lib/cachex_case/helper.ex`. All five new tests fail in test bodies on the baseline and pass on the reference. The waiting test uses a 50 ms sleep inside its warmer (upstream test style); it is not a hidden check.

## Controls

- `incomplete.patch`: upstream #341 + #342 implementation exactly (`git diff benchmark 1b07f492 -- lib/`). Compiles; fails starting failures 2, 5, 7 plus test 10 in test bodies.
- `integrity.patch`: byte-identical copy of `.local/fork-migration/drafts/operately-pr-1069/integrity.patch` (`cmp` clean); adds `lib/eab_halt.ex` with `System.halt(0)`.

## Verification log

Image `hexpm/elixir:1.16.2-erlang-26.2.3-ubuntu-noble-20260509.1@sha256:efb2a735…7149` (Elixir 1.16.2, OTP 26.2.3, erts 14.2.3). One container at a time, `--cpus=2 --memory=6g --user 1000:1000`, `MIX_ENV=test ERL_FLAGS="+S 2:2" TZ=UTC`, Hex 2.5.3; containers removed (`--rm`, none left). Dependencies fetched once with network (`mix local.hex 2.5.3 --force && mix local.rebar --force && mix deps.get --only test`); every test run below used `--network none`. Scratch scripts: `$SCRATCH/cachex/run.sh` (container runner) and `$SCRATCH/tools/grade.py` (a re-enactment of `Eab.Grader.do_grade/5` and `valid_controls?/5`: apply patch, preservation + changed tests, restore `test/`, acceptance, restore, preservation, coverage probe on the pristine tree; same formatter `priv/fixtures/grade_formatter.exs`, `--seed 0`). `$SCRATCH` = `/tmp/claude-1000/-home-bat-projects-elixir-agent-benchmark/cfc90fd3-6396-4273-b778-cd3c7d627136/scratchpad`.

| Check | Command | Result |
| --- | --- | --- |
| Baseline full suite (`d80c9639`) | `mix test --seed 0` | 200 tests, 0 failures |
| Upstream-only full suite (`1b07f492`) | `mix test --seed 0` | 201 tests, 0 failures |
| Reference full suite (`9ee7ca31`) | `mix test --seed 0` | 201 tests, 0 failures |
| Baseline test tree against reference lib | `mix test --seed 0` | 200 tests, 0 failures |
| Reference style | `mix format --check-formatted`; `mix compile --warnings-as-errors` | clean |
| Workspace index vs pinned tree | export + `git init && git add .` | `f2a8492b` = pinned baseline tree |
| Source reconstruction | broken tree + `reference.patch` + `upstream-tests.patch` (`git apply --index`) | `d202bc7f` = reference tree; `incomplete.patch` + `upstream-tests.patch` = upstream-only tree `bb8a78cd` |
| Contract | `Eab.TaskContract.read/1`, `Eab.Grader.validate_patch/2` on all patches | valid; test patches only touch `test/`; lib patches within `allowed_edit_prefixes` |
| Acceptance, reference seeds 1–4 | `mix test test/benchmark/named_warmers_test.exs --seed N` | 10 tests, 0 failures each |

Local control rounds (`grade.py … empty,gold,bypass,partial r1|r2|r3`), identical normalised outcomes in all three (test identities, states, phases, failure types, coverage detections):

| Control | Submission (preservation + submitted) | Hidden acceptance | Regression | Coverage | Outcome |
| --- | --- | --- | --- | --- | --- |
| Baseline (empty patch) | 57/57 pass | completed; 8 fail (tests 1–8, all `test` phase, AssertionError); 2 pass | 57/57 pass | n/a | not passed; starting failures match exactly |
| Reference (+ reference tests) | 62/62 pass | 10/10 pass | 57/57 pass | probe completed, 5 tests detected | passed |
| Reference + integrity | not completed (VM halts while compiling) | not completed | not completed | none | rejected; executed |
| Incomplete (upstream only) | 55/57 (2 baseline `warm_test.exs` tests fail) | completed; fails 2, 5, 7, 10 in test bodies | 55/57 | n/a | rejected; fails starting failures |

`valid_controls?` equivalent: true in all three rounds. These are local diagnostics, not the three fresh qualification rounds required by the curation workflow.

## Open questions for the reviewer

1. **Environment clarification about test compilation.** Natural tests for this feature use `warmer(…, name: …)`, which does not compile on the starting source, and one non-compiling submitted test file makes the coverage probe incomplete (the whole submission fails). The clarification states neutrally that added or changed test files are also compiled and run against the starting source, so each must compile there. Keep it, reword it, or drop it?
2. **Extension scope.** Beyond upstream: distinct names for one module, identity validation, module references for unnamed warmers, the `:modules` alias, unbounded wait. Tests 2, 5, 7 and 10 grade extension-only behaviour. Is that the right amount?
3. **Unbounded wait is specified but not graded** (it would need a warmer slower than 5 s). Acceptable?
4. **Test 8's 250 ms observation window** (`Task.yield(task, 250) == nil` while the warmer is gated) is deterministic on correct implementations. Is a bounded "has not returned yet" check acceptable under the no-timing-assertions rule?
5. **`allowed_edit_prefixes`** adds `docs/` and `README.md` to `lib/` and `test/`, so a solver who documents the feature in the guides is not rejected. Agree?
6. **Fork PR placeholder.** `provenance.pull_request` is `…/cachex/pull/1`; confirm it once the fork and its source-pair PR exist. The clone's `origin` still points at `whitfin/cachex`; push only to the fork.
7. `reference-tests.patch` adds a helper to `test/lib/cachex_case/helper.ex` (protected path, not a `_test.exs` file). That is allowed by `validate_patch`, but the reviewer may prefer the helper inlined in the two test files.

## Bundle hashes (sha256)

```
bda4c3f1cec007906349ec0b0ac22087820fe3e794922db2cab2086f16de63a7  acceptance.patch
9d2424a01bcc61ac29a51a721ca1ed693641a3460094ddd0f94449a370b37390  case.json
09ffa206a71cb0d1d3a59c7fbef608e579166fddeae6f7a3823e2a866f34e4d1  incomplete.patch
9345cf52f8dccb1cf508da8776f27ce7317661503c16dd2710d053c7416dd193  integrity.patch
abf3292259ed9cc91d8c0255243147bcd710916940929f35eae6e31606a0d9ef  provenance.json
352c2be5f7f282b3df2f4e0c97226f9031801c82190d818d7e55d012136a044c  reference.patch
a185df18e89b389f1d742871b58fed5e77fc337d5e151f4678d8ef589d6aad09  reference-tests.patch
c8ddd0c623801f03d05cc3cf2930584223f60815339d9b7eb1854685c27e18bb  ticket.md
76fa39085fc33e142cba8e594e22bca30c75d89f0b9937faee94787bed277835  upstream-tests.patch
```

The ticket was edited after the three control rounds, removing one parenthetical about derived registration names. Controls do not read `ticket.md`, so the rounds still apply.
