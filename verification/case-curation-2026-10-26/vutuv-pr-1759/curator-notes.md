# vutuv-pr-1759: curator notes

Status: **unadmitted draft, revision 1** (2026-10-26). Nothing has been pushed, imported, reviewed or qualified through `Eab.Candidates` yet, and no model has run. These notes are for curators only and stay outside the bundle.

## Case choice: vutuv, not the Craftplan fallback

vutuv's environment prepares and runs its tests offline, so the fallback (craftplan-pr-51) was not needed. These were the risks, and how each one played out:

- `image` → `vix` and `lazy_html`: both download a precompiled NIF during `mix compile`. vix bundles libvips in its NIF tarball. The grader's Docker build has network, so the NIFs end up in `_build`. After that, tests ran with no network.
- `ex_cldr`: vutuv commits the `de` and `it` locale files under `priv/cldr/locales`, and the package ships `en`/`und`, so compilation needs no download. Its own `CldrLocaleBundleTest` passes offline.
- `tz`: its periodic updater is deliberately left unsupervised.
- `ex_phone_number`: its metadata is bundled.
- `config/test.exs` already switches off every external fetcher.

The full suite ran offline on the upstream parent: 9,423 tests, 24 failures. All 24 come from the environment and none touch this feature:

- 23 in `Vutuv.PrecommitHookTest`: the Claude pre-push hook needs `jq`, which the image does not have.
- 1 in `VutuvWeb.LandingPageTest` ("every screenshot in the catalog is in the git index"): the screenshots are gitignored and were force-added upstream, so a workspace rebuilt with `git add .` (mine, and the grader's) does not track them.

## Source

| Item | Value |
| --- | --- |
| Upstream | wintermeyer/vutuv#1759, "suggest @-mentions while typing, and show them as chips". Closes #1748. MIT. |
| Upstream merge | `f24cc11d632f843eed82231e85b4f0cad9cba285` (squash, 2026-08-30, author Julian Pawlowski; co-authors Stefan Wintermeyer and Claude Opus 5). Tree `545cc0e1…`. The PR body says an AI agent wrote its text, which is exposure metadata. |
| Upstream parent | `a440373490f7c12be13ad37e445b5929f277e24c`, tree `e8e5531a…` |
| Local clone | `.local/new-cases/repos/vutuv` (full clone; `main` at `47841d73`) |
| Baseline branch | `codex/vutuv-pr-1759-benchmark` = `2ec029c3feb5bd149c18832adbf9840a0fd2f613`, tree `ad68bcd1…` (the parent plus one neutral preparation commit) |
| Upstream replay | `128b4941d1f31ccfaa1243f79369410b227305b2`, tree `11a8eba8…`. It is server side only and keeps the original author and author date. |
| Curator extension | `acdd44e2869e5fe6d96f34ad8787421a9bf15bb7` (= reference branch tip), tree `c2f50da6…`, parent `128b4941` |
| Reference branch | `codex/vutuv-pr-1759-reference` = `acdd44e2…` |
| Target fork | `https://github.com/Cinderella-Man/vutuv`. It does not exist yet, and the branches and the source-pair PR are unpublished. `provenance.json` assumes the draft PR will be **#1**; correct it if it is not. |

## What upstream changed, and what the replay keeps

Upstream touched 19 files (+3414/−1731). The replay keeps the server side.

These are kept byte-identical to upstream (checked with `git diff 128b4941 f24cc11d -- <paths>`, which is empty):

- `lib/vutuv/mentions.ex`:
  - `suggest/3`: 2-character minimum, 8 by default, followed accounts first, a 24-candidate pool per kind, blocks filtered after the pool;
  - `check_handles/1`: normalize, drop blanks, dedupe, cap at 50;
  - `resolvable_handles/1`: all members, plus pages only when public;
  - `max_check_handles/0`.
- `lib/vutuv_web/controllers/mention_controller.ex`: the `suggest` and `check` JSON actions and the row payload.
- `lib/vutuv_web/markdown.ex`: `mention_targets/1` now delegates to `Mentions.resolvable_handles/1`, the one shared resolution.
- `lib/vutuv_web/router.ex`: two GET routes in the `/system` scope, which uses the `[:browser, :settings_pipe]` pipelines (login required, activated account, noindex).
- The tests `mention_resolution_agreement_test.exs`, `mention_suggest_test.exs` and `mention_controller_test.exs`.
- From `lib/vutuv_web/components/ui.ex`, only the hunk that makes `organization_initial/1` public, because the controller calls it.

These are left out: the JS picker (`assets/js/mention_picker.js`, `markdown_editor.js`), CSS, the editor's `mention_limit` attribute and `data-mention-*` attributes in `ui.ex`, the composer's `mention_limit`, their two tests (`markdown_editor_test.exs` additions and `composer_mentions_test.exs`), the four gettext catalogs, and `docs/architecture/mentions.md` (it documents the omitted picker). The commit message of `128b4941` starts with a paragraph that lists these, followed by the full upstream message.

That leaves 4 implementation files plus one hunk. What has to stay consistent across them:

- the renderer, `check_handles/1` and the JSON endpoint must agree on which handles resolve;
- the ranking and exclusion queries over follows, blocks, moderation flags and page visibility must agree with the JSON row shape.

## Curator extension: exact ranking (one commit, `lib/vutuv/mentions.ex` only)

The upstream moduledoc promises "followed-first, and inside each group handle-prefix matches before name matches, then alphabetically". The upstream code breaks that promise in two ways:

1. **Members before pages.** Users and organizations were queried separately, concatenated, then stably partitioned by follow status. So within a group every member came before every page, whatever the spelling said.
2. **The 24-candidate pool.** Each kind ranked only its first 24 candidates by (prefix, name). A followee who matched only by name dropped out once 24 strangers' handles matched. Blocked members were removed **after** the pool was cut, so 24 blocked matches could leave nothing to offer. (The shortlist flagged this: "Either state the cap or keep fixtures under it.")

The extension:

- ranks both kinds in SQL by one key: `is_nil(follow.id)`, a handle-prefix `CASE`, `lower(name) COLLATE "C"`, then handle;
- LEFT JOINs the follow edge on the `(follower_id, followee_id)` / `(follower_id, followee_organization_id)` unique indexes;
- excludes blocks in both directions with `NOT EXISTS`, the style `Social.saved_users_page/3` uses;
- has each kind return its top `limit` rows with their key. `suggest/3` merges the two lists by the same key and takes `limit`.

The result is the true top `limit` of every eligible account, and the spec can state the order without a cap. `COLLATE "C"` keeps SQL's order identical to Elixir's binary ordering, which the merge uses. Ties on name break on the unique handle, so the order is total.

The unused `Identity` and `Social` aliases were removed and the `Block` alias added. `mix format --check-formatted` and `mix compile --warnings-as-errors` are clean on the reference.

Why this extension rather than the shortlist's "live composer warning": the warning would have needed a new visible UI string and a composer LiveView test. Its premise ("using the same resolution as the check endpoint, before the save refuses it") also conflicts with an asymmetry upstream chose on purpose: the save accepts a non-public page's handle, but the renderer and the check do not resolve it. The ranking extension, by contrast, makes the feature's own central rule exact. It is server side and stays in the same module.

Diagnostic M1 is the upstream replay without the extension, run against the hidden tests. It fails exactly the three tests that depend on the extension: cross-kind ranking, a followee behind 30 strangers, and blocked members crowding out a visible one.

## Spec decisions (ticket.md)

- **Suggest: matching.**
  - A member matches on handle prefix, or when first name, last name or "first last" contains the term. A page matches on root-handle prefix or when its name contains the term.
  - A handle that merely contains the term is not a match.
  - The term is normalized like `Handles.normalize/1` and matched literally (LIKE escaping).
  - There is a 2-character minimum.
- **Suggest: exclusions.**
  - Excluded: the viewer; members blocked in either direction; unconfirmed members (`nil` counts as confirmed); moderation-hidden members (frozen, deactivated, unreachable, or suspended until a time that has not passed); pages that are not public; pages without a handle.
  - Blocks never apply to pages, because they exist only between members.
  - Not excluded: pages the viewer manages. This is upstream behaviour, not stated, and not tested.
- **Ranking.**
  - The order is: followed (muted follows count), then handle prefix, then name ignoring case (a member's "first last" without honorifics, a page's name), then handle.
  - Members and pages share one order, and it applies to all matches before the limit.
- **Check.**
  - `{checked :: list, resolved :: MapSet}`. `checked` is normalized, blanks dropped, deduped in first-appearance order, and capped at the first 50.
  - `resolved` is exactly what `VutuvWeb.Markdown.render/1` links: any member (confirmation, moderation and blocks are irrelevant, because the renderer links profiles unfiltered), and pages only when public.
  - The spec states the asymmetry with the save's existence check explicitly.
- **Endpoints.**
  - They live under `/system/`, signed-in only. Signed-out requests get the usual redirect to `/` with no JSON.
  - `suggest` rows have exactly `kind`, `handle`, `name` (display name with honorifics), `avatar` (a URL or `null`; the `data:` placeholder becomes `null`; a page logo is a `/organization_images/<token>/…` URL) and `initials` (a member's first two words of first and last name, a page's first letter).
  - `check` answers exactly `known` (any order) and `checked`. Missing parameters give empty answers.
- **Non-goals:** the JS UI, gettext, remote `@user@host` completion, caching and rate limits. Docs are optional.

## Bundle layout decisions (worth a reviewer look)

1. **`allowed_edit_prefixes` = `lib/`, `test/`, `docs/`, `assets/`, `priv/gettext/`.**
   - The reference touches only `lib/`.
   - `docs/` is allowed because the spec says docs updates are welcome.
   - `assets/` and `priv/gettext/` are allowed so that a solver who wires up the (out-of-scope) picker, or follows the repository's own `CLAUDE.md` advice to run `gettext.extract --merge`, is not rejected wholesale.
   - Protected tests still decide the grade.
2. **No `upstream-docs.patch`.** The upstream docs change describes the omitted picker. The fixed tree reconstructs from `reference.patch` plus `upstream-tests.patch`.
3. **Curator test off the reference branch.** As in Guardian 748, `Eab.Provenance` reconstructs the fixed tree from `upstream-tests.patch`, so the branch's tests must equal upstream's. The curator's project-style test `test/vutuv/mention_suggest_ranking_test.exs` (3 tests, async, handles prefixed `rk`) lives only in `reference-tests.patch`, together with the 3 upstream test files.
4. **Neutral preparation commit `2ec029c3`:** `test/support/line_buffered_io.exs` and `test/test_helper.exs` (`ExUnit.start(max_cases: 2)`, with the sandbox mode line kept after it).
   - The adapter is byte-identical to Guardian's `c251a21` version apart from the module name (`Vutuv.Test.LineBufferedIO`).
   - It is defensive here: no dot-prefixed `EAB_` line appeared in any vutuv run, including the 9,423-test run on the **unprepared** parent with 24 failures. The race comes from the formatter design that Ash 3031 and Guardian 748 observed, and `valid_controls?` needs exact `starting_failures`.
   - `.tool-versions` already matches the image and is unchanged.
5. **Hidden tests are `async: false`.** They insert literal handles, and the project's rule forbids async modules sharing unique keys. Handles are prefixed per file (`ep…`, `chk…`, `sg…`/`ada…`/`kai…`/`jo…`).
6. **Missing interface becomes a named assertion.**
   - `suggest/2,3` and `check_handles/1` are reached through `Code.ensure_loaded!` plus `assert function_exported?`, then `apply/3`.
   - On the baseline, routes answer the site's 404 page, which `json/3` reports as "GET … answered 404, expected 200".
   - `request/3` also turns a `NoRouteError` into a `flunk`.
   - The test files compile on the baseline without warnings about undefined functions.

## Runtime

- Image `hexpm/elixir:1.20.0-erlang-28.5.0.1-ubuntu-noble-20260509.1@sha256:dc6e4029e6937bce5b449dbd3240cf46796579b4f5aca64b4d6e91b0493823f1`. It matches `.tool-versions` (`elixir 1.20.0-otp-28`, `erlang 28.5.0.1`) and CI (`erlef/setup-beam`, same versions).
- PostgreSQL `postgres:17.10@sha256:7958605b474b3d264a969cb3a123d6aa00ad1e1fe9da8a69984dabb704d93317`. CI uses `postgres:17`, and 17.10 was current at the merge date.
- `DATABASE_HOST=127.0.0.1`, which `config/test.exs` reads. Username, password and database come from config.
- `baseline.commands`: `mix ecto.create --quiet`, `mix ecto.migrate --quiet` (367 migrations). The `test` alias runs both again, as no-ops.
- `setup_commands: ["mix compile"]`, which needs network for the vix and lazy_html NIF downloads. The grader's `docker buildx build` has network.
- I used a local toolchain image `vutuv1759-toolchain:local` built FROM the pinned image with the exact apt, user and `mix local.hex 2.5.3` lines from `Eab.Fixtures.dockerfile/4`.
- `test_timeout: 900`. This is a watchdog value for a large app's compile plus 263 to 300 tests, not a performance claim.
- The clarification names the pre-existing environment failures (jq, untracked screenshots) so a solver running the whole suite is not misled.

## Hidden acceptance tests: assertion mapping

The files are:

- `test/benchmark/mention_suggest_test.exs` (S, `Vutuv.DataCase`)
- `test/benchmark/mention_check_test.exs` (C, `Vutuv.DataCase`)
- `test/benchmark/mention_endpoints_test.exs` (E, `VutuvWeb.ConnCase`, real PIN login via `create_and_login_user/1`)

They have no network and no timing. The only clock contact is the moderation predicate's `NOW()` against fixed dates (frozen and deactivated `2026-01-01`; suspended until `2999-01-01`, so hidden; suspended until `2001-01-01`, so offered).

| Test | Spec basis | Baseline | Reference | Incomplete |
| --- | --- | --- | --- | --- |
| S suggest matches members by handle prefix or name and pages by root handle prefix or name | Who matches; result structs | fail | pass | pass |
| S suggest ranks followed accounts first, then handle prefix matches, then by name and handle | Ranking (11 accounts, mixed kinds, muted follow, name tie broken by handle) | fail | pass | pass |
| S suggest returns at most eight accounts by default, or the given limit, from the top of the ranking | Limit, default 8 | fail | pass | pass |
| S suggest never offers the viewer, blocked, unconfirmed or hidden members, or pages that are not public | Exclusions, plus 4 positive controls (ordinary, legacy `nil`, past suspension, public page) | fail | pass | **fail** |
| S suggest needs two characters after normalization and matches the term literally | The term | fail | pass | pass |
| S a followed account ranks first however many other accounts match | "applies to all matches" (30 prefix strangers + 1 followee by name) | fail | pass | pass |
| S accounts that may not be offered never take the place of ones that may | "Excluded accounts never use up a place" (30 blocked, both directions) | fail | pass | **fail** |
| C check_handles normalizes, de-duplicates and caps the handles it checks | Check: `checked` | fail | pass | pass |
| C check_handles resolves exactly the handles the renderer links | Check: `resolved` as a `MapSet`, plus per-handle agreement with `render/1` | fail | pass | pass |
| C rendered mention links and the save-time mention check are unchanged | Compatibility (preservation inside acceptance) | pass | pass | pass |
| E suggest answers rows with kind, handle, name, avatar and initials | JSON row shape (exact member map, page logo URL, 5 keys) | fail | pass | pass |
| E suggest answers for the signed-in member with their follows and blocks | Endpoint uses the signed-in viewer; limit 8; short or missing q | fail | pass | pass |
| E check reports which handles are known and which were checked | Check JSON (exact keys, order, cap, missing param) | fail | pass | pass |
| E both endpoints are for signed-in members only | Access (signed-out redirect, no JSON) | fail | pass | pass |

Five requirement groups in `case.json` map all 14 required checks: suggest-ranking (4), suggest-exclusions (3), check-matches-renderer (2), rendering-unchanged (1) and json-endpoints (4). `starting_failures` lists the 13 checks that fail on the baseline. `TaskContract.read/1` accepts the contract.

**Incomplete control:** the reference with the block exclusion applied in one direction only (members the viewer blocked are dropped; members who blocked the viewer are still offered). It is a plausible miss, and it compiles. It fails S-exclusions and S-crowd-out in the test body, and both are in `starting_failures`. E-follows-and-blocks still passes, because there the viewer is the blocker.

These diagnostic mutants are not controls. Each ran the 14 hidden tests on the reference:

- M1, the upstream replay without the extension: fails S-ranking, S-followee-behind-30 and S-crowd-out.
- M2 is the incomplete control above.
- M3, `check_handles` answering the save's question (any holder): fails C-agreement and E-check.
- M4, the renderer and check both linking non-public pages, so they still agree with each other: fails C-agreement, C-unchanged and E-check.

## Preservation

```
mix test test/vutuv/mentions_test.exs test/vutuv/mention_existence_test.exs test/vutuv/mention_limit_test.exs test/vutuv/mention_notifications_test.exs test/vutuv/mentions_local_address_test.exs test/vutuv/handles_test.exs test/vutuv/handle_availability_test.exs test/vutuv_web/markdown_test.exs test/vutuv_web/markdown_mentions_test.exs test/vutuv_web/markdown_local_address_test.exs test/vutuv_web/mention_form_test.exs test/vutuv_web/organization_mention_test.exs test/vutuv_web/components/ui_test.exs test/vutuv_web/components/markdown_editor_test.exs test/vutuv_web/reserved_slugs_router_test.exs
```

These 263 tests cover:

- the mention grammar, existence, limit, notifications and local addresses;
- handle normalization and availability;
- the Markdown renderer's mention and local-address links;
- page mentions;
- the UI component (`organization_initial`, now public) and the editor component;
- the router's reserved-root-words contract, which guards the "under `/system/`" rule.

They pass on the baseline and the reference, with no skips or exclusions.

## Verification log (2026-10-26)

Setup for every run:

- Containers used `vutuv1759-toolchain:local` (the pinned image plus the grader's toolchain lines) with `--cpus=2 --memory=6g --user 1000:1000 --rm`.
- PostgreSQL ran in a `--network=none` container (`--memory=1g --cpus=1`), and the test container joined its network namespace (`--network=container:<db>`, as `Eab.Sandbox` does), so tests had no external network.
- One database and test pair ran at a time, and a fresh database was used for every run.
- Dependencies were fetched once with network (`mix deps.get --only test`, then `mix compile`). Later workspaces copied `deps/` and `_build/` from that baseline workspace.
- Workspaces are `git archive` exports re-initialized with one commit, like the grader's.
- Every test run used `MIX_ENV=test ERL_FLAGS='+S 2:2' TZ=UTC DATABASE_HOST=127.0.0.1` and the grader's command form: `elixir -r formatter.exs -S mix test … --seed 0 --formatter ExUnit.CLIFormatter --formatter ElixirAgentBenchmark.TrustedFormatter`, with `priv/fixtures/grade_formatter.exs`.
- Scripts are in the session scratchpad `vutuv-1759/scripts/` (`run.sh`, `mkws.sh`, `grade.sh`, `control.sh`, `mkpatch.sh`, `decode.py`, `check_controls.py`, `contract_check.exs`) and logs in `vutuv-1759/logs/`.
- No durations were recorded or interpreted. Mix printed its usual "Finished in" line, and it was ignored.

Full suites:

| Tree | Result |
| --- | --- |
| Upstream parent `a4403734`, before preparation | 9,423 tests, 24 failures (23 `PrecommitHookTest`: no `jq`; 1 `LandingPageTest`: untracked screenshots), rc 2 |
| Prepared baseline `2ec029c3` | 9,423 tests, the same 24 failures (identical test IDs), rc 2 |
| Reference branch `acdd44e2` (includes the 3 upstream test files) | 9,452 tests (+29 upstream), the same 24 failures, rc 2 |
| Reference branch + the curator test (= the full `reference-tests.patch` set) | 9,455 tests (+3), the same 24 failures, rc 2 |

No run had a skipped or excluded test. The reference adds no failure, and every new test passes.

Grader-flow controls (`control.sh`) repeat `Grader.do_grade`:

1. apply the patch;
2. run the submission phase (preservation plus changed tests);
3. restore `test/`;
4. apply the acceptance overlay;
5. run hidden;
6. restore `test/`;
7. run regression.

| Control | Submission | Hidden (14) | Regression |
| --- | --- | --- | --- |
| Unchanged | 263/263 pass | 1 pass, 13 fail, all phase `test`; the set equals `starting_failures` exactly | 263/263 pass |
| Reference + reference-tests | 295/295 pass | 14/14 pass | 263/263 pass |
| Incomplete | 263/263 pass | 12 pass, 2 fail (exclusions, crowd-out), phase `test`, both in `starting_failures` | 263/263 pass |
| Reference + reference-tests + integrity | no tests (compile-time `System.halt(0)`), not completed | not completed | not completed |

- **Coverage probe.** Applied `reference-tests.patch` alone to the baseline and ran the 4 changed files. It completed with 32 tests, rc 2, and all 32 failing in the test phase (26 `UndefinedFunctionError`, 6 `RuntimeError` from 404s). Every one passed in the reference submission.
- **Control replay.** `check_controls.py` replays the `valid_controls?` conditions on these outcomes, and every condition holds.
- **Reporter check.** No dot-prefixed `EAB_` lines appeared in any log.
- **Source reconstruction.** Starting from the baseline export (tree `ad68bcd1`, equal to the branch), `git apply --index` of `reference.patch` and then `upstream-tests.patch` gives tree `c2f50da6…`, which equals the reference branch tree.
- **Contract check.** `contract_check.exs` loads the project's own `task_contract.ex`, `grader.ex` and `provenance.ex` with the host Elixir 1.20.3, and found:
  - `TaskContract.read/1` succeeds (14 required, 13 starting);
  - `Provenance.validate!/2` succeeds;
  - `validate_patch` returns `{:ok, []}` for the three test patches against `test/`, and for `reference.patch`, `incomplete.patch` and `integrity.patch` against `allowed_edit_prefixes`.
- **Upstream tests (29).** They pass on the replay `128b4941` and on the extension.
- **Formatting.** `mix format` produced no changes in the hidden tests. The curator test was formatted.
- **Project gates.** `mix compile --warnings-as-errors --force`, `mix format --check-formatted` and `mix credo --strict` are clean on the prepared baseline and on the reference with the curator test. These are the project's own `precommit` gates, apart from `deps.unlock --unused`. Credo found no issues in either tree, and the baseline tree includes the preparation files. The hidden test files were format-checked separately and are not in either tree.

Cleanup: every container ran with `--rm`, and the database containers were removed by the run script's exit trap. No `vutuv1759-*` container or Docker network remains. The derived workspaces were deleted. The scratchpad keeps the dependency workspace `ws-baseline`, the logs and the scripts, and the local image `vutuv1759-toolchain:local` is kept for re-verification.

`integrity.patch` is a byte copy of `.local/fork-migration/drafts/operately-pr-1069/integrity.patch` (sha256 `9345cf52…d193`).

## Bundle hashes (sha256)

```
5fbc33697b82b72581ca9df79df0b25ba06624778bb66e39e3cb25d08ca43921  acceptance.patch
c664c0ea3d5eba9bb84e93788207f668854da6856f3208683770f74fd6d1e4d1  case.json
59deddce268f0853e12f225d47ddc08c36d8b1d569195a3445b3585d5752b977  incomplete.patch
9345cf52f8dccb1cf508da8776f27ce7317661503c16dd2710d053c7416dd193  integrity.patch
9dc20512debfccb380e5826f8215fd5c06aab5f42b618112ede1f0e86bb85ef3  provenance.json
330c6c5f5461010bf66c1783971fcc369732def9897197539e08bc31ff08bc1d  reference.patch
866bce7b44a6cfac75a4ea3dfdfa059ee69c41d5dd8282dc7fafacba3f57b08c  reference-tests.patch
19deca550958d05f03951b13d745e3411d299a54c7a5973e1f984243b319c6f5  ticket.md
c6bdc3b6214ea374e92490dffcd23e30efe9b1c17bf0ff0e02e56bf947ee1e02  upstream-tests.patch
```

## Remaining gates

1. Create the fork centrally, push both branches, open the draft source-pair PR, and fix `pull_request` if it is not #1.
2. Import through `Eab.Candidates`, get an independent requirements-first review, and run three fresh qualification rounds. The first round is also the first build through the real `Eab.Fixtures` recipe, including the in-build NIF downloads.
3. Run two Opus 5.5 xhigh validations (ADR 0012 and 0013).

## Open questions for the reviewer

- **The extension changes upstream's observable order.** Mixed member and page results now interleave by name, and followees and visible accounts are never lost past 24 matches. Is that an acceptable curator extension, or should the case keep upstream's "members before pages" order and state the 24-pool cap instead?
- **Wide `allowed_edit_prefixes`** (`docs/`, `assets/`, `priv/gettext/`).
- **Exact JSON assertions.** E-rows asserts the exact member row (`"name" => "Dr. Ada Lovelace"`, `"initials" => "AL"`) and a page avatar URL containing the logo token. The spec states all of these, but they are the most representation-specific checks in the case.
- **The neutral preparation is defensive.** No reporter fault was observed in vutuv. Drop it if the reviewer prefers a pure upstream parent (`.tool-versions` already matches).
