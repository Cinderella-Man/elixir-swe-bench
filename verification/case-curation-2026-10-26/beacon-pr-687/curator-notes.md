# beacon-pr-687: curator notes

Status: **unadmitted draft**, prepared on 2026-10-26 and amended the same day after independent review (see "Review amendments"). Nothing is pushed, imported, reviewed or qualified through `Eab.Candidates` yet, and there are no model runs. These notes are for the curator only and stay outside the bundle.

## Source

| Item | Value |
| --- | --- |
| Upstream | BeaconCMS/beacon #687, "Beacon generates `sitemap.xml` per site and a `sitemap_index.xml`", resolves #169. The adjacent #700 is "Beacon generates `robots.txt` per site". MIT. |
| #687 merge | `1aa11357746073f0f9e321e1cdf2ba1e62a51682`, a squash with a single parent (2025-02-03, author Andrew Berrien). Tree `8eed015b…`. |
| #700 merge | `9dbfa204b907210755915112b3d4e125b9193753`, a squash with single parent `1aa11357` (25 minutes later, same author). Tree `57646316…`. |
| Upstream parent | `86c9ffd2c46558313725fa7ffddbf72bd926b2b3`, tree `2c2b901f…`. The deep dive corrected this from the older dossier's `78c0fef0`. |
| Local clone | `.local/new-cases/repos/beacon`, a full clone of upstream (`main` at `2e7b8c2`) |
| Baseline branch | `codex/beacon-pr-687-benchmark` = `9d657a8b5983da4976073ddfed730deb8d885dfc`, tree `a868fa90…`. It is the parent plus one neutral preparation commit. |
| Reference branch | `codex/beacon-pr-687-reference` = `e54f3536333cbfd1a1fc023a286f5c771b26a0e1`, tree `63f6cb8b…` |
| Upstream replays | `aaa40d9e` (= #687) and `f3905e74` (= #700). Authorship and dates are kept, and the committer is the curator. `git patch-id --stable` equals upstream for both (`96aca18f…` and `32173daa…`). Replaying both onto the **unprepared** parent gives exactly upstream tree `57646316…`. |
| Curator extension | `e54f3536`, parent `f3905e74` (tree `4780db4a…`) |
| Target fork | `https://github.com/Cinderella-Man/beacon`. Nothing is pushed. `provenance.json` assumes the source-pair PR will be **#1**, so correct it if not. |

### Follow-ups checked

| Commit | Content | Disposition |
| --- | --- | --- |
| `c87d8636` (same day) | Better esbuild error handling in `runtime_js.ex` | Unrelated, not replayed |
| `9dde49dc` (same day) | `mix beacon.gen.site`: the generated site endpoint's `Plug.Static` stops serving a static `robots.txt`, so Beacon's is not shadowed | **Not replayed.** Generators are a spec non-goal. See open question 5. |
| `c243a49` #740, `c951d31` #746, `98ed94e` #749 | Site-endpoint redesign; move the index and robots.txt to the proxy host; build the index URL from the proxy endpoint | Not replayed. This is the later product redesign the deep dive warns about. |

## What upstream changed (9 implementation paths)

- `#687`:
  - `Beacon.Router`: each `beacon_site` gets `GET /sitemap.xml`.
  - A new `beacon_sitemap_index/1` macro is imported by `use Beacon.Router`.
  - `__before_compile__` adds a `__beacon_scoped_prefix_for_site__(_) -> nil` fallback.
  - Routes module (`loader/routes.ex`): new `beacon_page_url/2` and `beacon_sitemap_url/1`, built from the endpoint URL, the scoped prefix and the path.
  - New `SitemapController` (`:index` lists `Registry.running_sites/0` sorted, `:show` lists `Content.list_published_pages(site)`, with `lastmod` = `updated_at`), plus `SitemapXML` and two `.xml.eex` templates.
  - Also changed: `.formatter.exs` (`locals_without_parens`) and `config/test.exs` (`EndpointSite` config renamed to `EndpointB`, host `site_b.com`).
- `#700`: `GET /robots.txt` per site, plus `RobotsController`, `RobotsTxt` and `robots.txt.eex`. It is served as `text/txt`.
- Tests:
  - New `sitemap_controller_test.exs` (2 tests) and `robots_controller_test.exs` (1 test).
  - Fixture rework: `endpoint_b.ex`; the router mounts `:host_test` on host `site_b.com` and declares the index; `NoRoutesRouter` gains `use Beacon.Router`.
  - `media_library_controller_test.exs` loses its setup.
  - `install_test.exs` line numbers change.

Upstream gaps found while specifying (each is now a decided behaviour in `ticket.md`):

1. `list_published_pages/2` defaults to `per_page: 20`, so a site with more than 20 published pages gets a truncated sitemap. Upstream `main` still calls it without options.
2. The `.xml.eex` templates are compiled with `EEx.SmartEngine` (no escaping for the `xml` format). A valid page path such as `/q&a` (`Beacon.Schema.validate_path/1` only rejects space, `?` and `=`) produces malformed XML.
3. The index crashes (`UndefinedFunctionError`, wrapped in `Beacon.InvokeError`) if any running site's configured router does not `use Beacon.Router`. The baseline test fixtures have one: `:no_routes` with `NoRoutesRouter`. Upstream avoided it by changing the fixture.
4. `robots.txt` is served as `text/txt`, which is not a registered type.

## Curator extension (`e54f3536`)

Its author is the curator. The message starts "Curator extension for the elixir-agent-benchmark case beacon-pr-687; not part of upstream". It changes 4 lib files and no tests:

- `sitemap_controller.ex`: `list_published_pages(site, per_page: :infinity)`. The index first filters `running_sites()` to sites whose configured router is loaded and exports `__beacon_scoped_prefix_for_site__/1`.
- `sitemap.xml.eex` and `sitemap_index.xml.eex`: `<loc><%= Plug.HTML.html_escape(...) %></loc>`. Whitespace is unchanged, so upstream's exact-string tests still pass.
- `robots_controller.ex`: `put_resp_content_type("text/plain")`. The upstream robots test (`response_content_type(conn, :txt)`) still passes.

It deliberately leaves out:
- `noindex` exclusion. The shortlist suggested it as optional. It is a new product rule and is a non-goal here.
- The cache header typo (`"public max-age=300"`). It is not specified.
- Dynamic-path pages. Whether they are listed is not specified.
- The generator follow-up.

Checks:
- Under Elixir 1.18.4, `mix format --check-formatted` is clean on both baseline and reference.
- `mix credo --strict` reports no issues on baseline (1982 mods/funs) or reference (2002).
- The full suite passes on the reference branch (see the log below).

## Spec decisions (`ticket.md`)

| Question | Decision |
| --- | --- |
| Where the files live | `<full mount path>/sitemap.xml` and `<full mount path>/robots.txt` for every `beacon_site`, with no router change. The index is opt-in via `beacon_sitemap_index/1`, at the given path inside the enclosing scope, and may be declared several times. This is the #687 placement; the #746 top-level-host layout is a non-goal. |
| URL construction | Site endpoint `url/0`, then the full mount path, then the page path. A trailing slash is not significant (root page `/`). Host-scoped mounts use their own endpoint. |
| Which pages | Published versions only. Drafts, unpublished pages and unpublished draft edits (path, timestamp) are excluded. Every page is listed (no cap). Order is not significant. |
| `lastmod` | The published version's `updated_at`, as an ISO 8601 date-time with offset. Fractional seconds and `Z`/`+00:00` are all acceptable; a date alone is not. |
| XML well-formedness | `&` and `<` are entity-escaped; percent-encoding is also accepted. |
| Index membership/order | Every running site mounted by its configured router, including other hosts. Sites that are not mounted are omitted, and so are sites whose router lacks `Beacon.Router`. Entries are sorted ascending by URL string, with an optional `lastmod`. Declaring the index only in a router other than the sites' router is explicitly unspecified (see the diagnostics: a router-local alternative passes). |
| robots.txt | `text/plain`; a `User-agent: *` group with no blocking `Disallow`; exactly one `Sitemap:` line, the site's own sitemap. Comments are optional. |
| Content types | XML is `text/xml` or `application/xml`. Charset is not graded. |
| Non-goals | changefreq/priority, noindex, splitting/gzip, configurable robots rules, proxy-endpoint placement, caching headers, generators, non-ASCII percent-encoding, endpoint `url: [path: …]`, docs |

## Bundle layout decisions

1. **`allowed_edit_prefixes`** = `lib/`, `test/`, `config/`, `.formatter.exs`, `CHANGELOG.md`, `guides/`. `reference.patch` must carry the upstream `.formatter.exs` and `config/test.exs` hunks, because only test and Markdown files can go elsewhere for source reconstruction. Adding the new macro to `locals_without_parens` is also a natural solver edit, and rejecting the whole submission for it would be harsh.
2. **Hidden fixtures modify shared test support**, in the acceptance overlay only:
   - `test/support/routers.ex` mounts `:host_test` on host `site_b.com` (existing `beacon_site` API only). It declares `beacon_sitemap_index` at `/sitemap_index.xml` and `/seo/all-sitemaps.xml` **inside `if Code.ensure_loaded?(Beacon.Router) and macro_exported?(Beacon.Router, :beacon_sitemap_index, 1)`**, using a qualified remote macro call. On code without the macro the router still compiles: the call is not expanded and never runs. The missing index then fails in the test body. A named assertion with the same condition comes first. The `Code.ensure_loaded?/1` guard is the reviewer's requested hardening. This satisfies the coordinator's rule that hidden tests never need new modules, routes or macros at compile time.
   - `test/test_helper.exs` puts a full `Beacon.BeaconTest.EndpointSite` config with host `site_b.com` before the endpoints start. That makes the hidden tests independent of `config/test.exs`, which upstream and solvers may change.
3. **`reference-tests.patch`** holds curator tests in project style, because upstream's fixture changes (`beacon_sitemap_index` in the router) do not compile on the baseline. It contains `sitemap_controller_test.exs` (5 tests) and `robots_controller_test.exs` (1), adapted from upstream with literal URLs, and the same guarded fixture changes. All 6 fail in test bodies on the baseline and pass on the reference. `upstream-tests.patch` keeps upstream's test changes byte-exact for reconstruction. As in Guardian, the curator tests are not committed on the reference branch.
4. **`upstream-docs.patch`** holds only upstream's CHANGELOG lines. The extension changes no Markdown.
5. **Neutral preparation commit** `9d657a8`: `test/support/line_buffered_io.exs`, byte-identical to the Guardian 748 adapter apart from the module name (`Beacon.BeaconTest.LineBufferedIO`), required from `test_helper.exs` before `ExUnit.start(exclude: [:skip], max_cases: 2)`. `test/support/*.exs` is not in `elixirc_paths`, so it is only loaded by the helper. There is no `environment.patch`.
6. **`incomplete.patch`** is the full reference implementation without the sitemap index. The `beacon_sitemap_index/1` macro and its import, the `:index` action and `sitemap_index.xml.eex` are removed. It is lib-only (no `.formatter.exs` or `config/` hunks). It compiles and passes everything except the index check.
7. **`integrity.patch`** is a byte copy of `.local/fork-migration/drafts/operately-pr-1069/integrity.patch` (`cmp` clean, sha256 `9345cf52…d193`).

## Runtime

- Image `hexpm/elixir:1.18.4-erlang-27.3.4-ubuntu-noble-20260509.1@sha256:11ee3fe5aed7b729f2783b8ae001371a92f5cfe025e84a97b4af06342264493c`, the same digest Guardian 748 pins. Upstream CI at `86c9ffd` ran this lockfile only on OTP 27 / Elixir 1.18. Its minimum job overrides Phoenix and LiveView versions. The locked `solid` declares `~> 1.16`, and `igniter` and `spitfire` declare `~> 1.15`; there are no version warnings on 1.18.4.
- The first draft used Elixir 1.14.2 / OTP 25.2, the deep dive's toolchain. The review replaced it, because under 1.14.2 `mix format` rewrites the root `dev.exs`, which is outside `allowed_edit_prefixes`. That evidence is archived under `logs/superseded-1.14/`.
- PostgreSQL `postgres:16.4-alpine@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c`, the latest version in upstream CI at that commit. `DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/beacon_test`. The `mix test` alias runs `ecto.create --quiet` and `ecto.migrate --quiet` itself. Migrations live in `test/support/migrations` (Repo `priv: "test/support"`), not `priv/repo/migrations`, so `Eab.DatabaseSeed.describe/2` will see no migration files. The alias covers that, but it is worth knowing for database-seed reuse.
- `setup_commands`: `mix compile`, `mix esbuild.install` and `mix tailwind.install --no-assets`. These fetch esbuild 0.23.0 from npm and tailwind 3.4.4 from GitHub into `_build/`. They need the network, so they belong in preparation. `Beacon.Boot` refuses to boot the live-mode `:booted` site without them. NIFs (`ex_brotli`, `mdex`, `vix`) are downloaded precompiled during `mix compile`. On 1.18.4 the fetch logged two TLS `alert_decode_error` notices during compilation, but it exited 0 and every artifact was present.
- **`ERL_FLAGS="+S 4:4"`**, not the usual `+S 2:2`. The test repo's `pool_size` is `System.schedulers_online() * 2`. With 2 schedulers the pool of 4 is exhausted while `:booted` boots (runtime CSS and JS loader workers hold sandbox connections in auto mode). `DBConnection` drops queued checkouts, `Beacon.Boot` fails and `test_helper.exs` exits before any test runs. This was observed once on the baseline full suite under 1.14.2. The setting is kept on 1.18.4 as instructed, and it was not re-tested there with `+S 2:2`. With 4 schedulers (pool 8) every run in this log booted. The container is still capped at `--cpus=2`. See open question 1.
- The workspace index after setup equals the pinned tree: after `git init && git add .`, `git write-tree` gives `a868fa90…` = the baseline tree.
- `test_timeout` 900 is a watchdog only.

## Hidden acceptance tests

The file is `test/benchmark/crawler_files_test.exs` (`Beacon.Benchmark.CrawlerFilesTest`, ConnCase, `async: false`). It parses XML with `:xmerl_scan` (`namespace_conformant: true`) and compares namespace-expanded names, so whitespace, prefixes and attribute order do not matter. `loc` values are compared after `URI.decode/1` and with a trailing `/` stripped. `lastmod` must parse with `DateTime.from_iso8601/1`. Controlled values are compared with `DateTime.compare/2`: two pages get a fixed `updated_at` (`2024-05-06T07:08:09Z` and `2023-01-02T03:04:05Z`) through `Repo.update_all` before publishing. Every other `lastmod` is format-checked only, so there is no wall-clock dependence. There are no sleeps and no network.

Every request goes through `request!/1`, which turns a raised exception (on the baseline, `Beacon.Web.NotFoundError` from the site catch-all) into `flunk/1`. A missing route is therefore a named assertion failure in the test body.

Columns: Base = baseline, Inc = incomplete control, M1 = upstream #687 + #700 lib only, M2 = `lastmod` = `utc_now()`, M3 = URLs ignore the scoped prefix, Alt = an independent alternative implementation (described below). `F` means failed in the test phase with `ExUnit.AssertionError`.

| # | Test | Spec basis | Base | Inc | M1 | M2 | M3 | Alt |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | each site serves its own published pages at its mount path | sitemap.xml: one url per page, absolute loc, isolation; edge case: same path, different hosts | F | pass | pass | pass | F | pass |
| 2 | sitemap entries reflect the published version of each page and its last update | published only; `lastmod` = published `updated_at` | F | pass | pass | **F** | pass | pass |
| 3 | sitemap lists every published page of a site however many it has (25 pages) | "however many" | F | pass | **F** | pass | F | pass |
| 4 | sitemap stays well-formed XML when a page path contains XML special characters (`/q&a`, `/a<b`) | well-formed XML | F | pass | **F** | pass | pass | pass |
| 5 | a site without published pages serves an empty sitemap | empty urlset | F | pass | pass | pass | pass | pass |
| 6 | robots.txt allows crawling and points at the site's own sitemap (4 sites, incl. `site_b.com`) | robots.txt | F | pass | **F** (`text/txt`) | pass | F | pass |
| 7 | the sitemap index lists the sitemap of every mounted site in URL order (`/sitemap_index.xml`, `/seo/all-sitemaps.xml`) | Public interface, sitemap index | F | **F** | **F** (crash on `:no_routes`) | pass | F | pass |
| 8 | pages and existing site routes keep working beside the crawler files (`/about`, `/sitemap`, `/robots`, `/other/contact`, 4× `__beacon_check__`) | Edge cases, compatibility | pass | pass | pass | pass | pass | pass |

`starting_failures` are tests 1–7. `required` is all 8. Test 8 is a positive preservation check, so disabling page routing cannot pass.

The expected index is `nested/media`, `nested/site`, `other`, root (all `http://localhost:4000`) and `http://site_b.com:4000/sitemap.xml`. Five running sites are omitted:
- `:no_routes`, whose router has no Beacon routes;
- `:data_source_test`, `:raw_schema_test`, `:default_meta_tags_test` and `:lifecycle_test*`, which are configured with the test router but not mounted.

The alternative implementation is written independently of the reference (`.local/new-cases/work/beacon-pr-687/alt.patch`). It uses:
- one controller that builds iodata, with no templates or view;
- `application/xml`;
- percent-encoding (`%26`, `%3C`) instead of entities;
- `lastmod` as `%Y-%m-%dT%H:%M:%S+00:00`;
- root pages with a trailing slash;
- robots with an empty `Disallow:` and a blank line;
- an index listed from the serving router's `__beacon_sites__()` instead of the registry;
- a plain `Phoenix.Router.get` in the macro.

It passes all 8, so the checks do not depend on the reference's representation choices.

Requirement groups in `case.json`:

| Group | Tests |
| --- | --- |
| site-sitemaps | 1, 5 |
| published-pages | 2, 3, 4 |
| robots-txt | 6 |
| sitemap-index | 7 |
| compatibility | 8 |

## Preservation

`mix test test/beacon/router_test.exs test/beacon/loader/routes_test.exs test/beacon/router_server_test.exs test/beacon/content_test.exs test/beacon_web/live/page_live_test.exs test/beacon_web/controllers/media_library_controller_test.exs test/beacon_web/controllers/assets_controller_test.exs test/beacon_web/controllers/error_html_test.exs test/mix/tasks/gen_site_test.exs`

This is 192 tests. They cover:
- router macros, options and `reachable?/2` (including the router without Beacon routes);
- routes-module helpers and `~p` with scoped prefixes;
- page path lookup;
- `Content`, including `list_published_pages`;
- LiveView page rendering;
- media and asset routes inside mounts;
- error pages;
- router generation by `beacon.gen.site`.

All 192 pass on the baseline, the reference and the incomplete control.

`test/mix/tasks/install_test.exs` is **excluded**. Its "add :beacon dep into formatter config" test copies Beacon's own `.formatter.exs` into a generated project and asserts line numbers. Any new `locals_without_parens` entry shifts them, which is why upstream edited the test. Baseline tests against the reference lib fail exactly that one test, apart from the network test.

## Verification log (2026-10-26)

Setup:
- One test container at a time, from a local toolchain image (`beacon687-toolchain:1.18`) built from the pinned 1.18.4 image with the controller's `Fixtures.dockerfile` toolchain steps: apt packages, `agent` uid 1000, Hex 2.5.3, rebar.
- Each container ran with `--cpus=2 --memory=6g --user 1000:1000 --tmpfs /tmp`.
- Dependencies, NIFs, esbuild and tailwind were fetched once with network (`mix deps.get --only test && mix deps.clean --unused && mix compile && mix esbuild.install && mix tailwind.install --no-assets`).
- Every test run used a fresh `postgres:16.4-alpine` container on an `--internal` Docker network (`beacon687-net`). Every 1.18.4 run limited it to 1 CPU and 512 MB, matching the controller. The test container joined its network namespace (`--network container:beacon687-db`), so the tests had no external network.
- Grader-flow runs used the grader's command form, `elixir -r formatter.exs -S mix test … --seed 0 --formatter ExUnit.CLIFormatter --formatter ElixirAgentBenchmark.TrustedFormatter`, with `priv/fixtures/grade_formatter.exs`.

Scripts and logs are in `.local/new-cases/work/beacon-pr-687/{scripts,logs}`:
- `grade.py` re-enacts `Grader.do_grade/5` and `valid_controls?/5` with one fresh DB per box.
- `hidden_only.py` is used for the diagnostics.
- `db.sh`, `run.sh`, `mkws.sh`, `fetch.sh`.

No durations were recorded or interpreted.

Full suites (`mix test --seed 0`, `ERL_FLAGS=+S 4:4`), Elixir 1.18.4:

| Tree | Result |
| --- | --- |
| Prepared baseline `9d657a8` | 2 doctests, 398 tests, 1 failure: `Beacon.Web.ComponentsTest` "embed displays youtube video", which needs the network (oEmbed). |
| **Reference `e54f3536`** (upstream tests) | 2 doctests, 401 tests, 1 failure (same network test) |

The superseded Elixir 1.14.2 runs gave the same counts. They also showed that baseline tests against the reference lib fail only the network test and the `install_test` formatter line numbers, which is the basis for excluding `install_test.exs`. With `+S 2:2`, the 1.14.2 baseline did not start: `Beacon.Boot` failed with a `DBConnection` pool error. Those logs are in `logs/superseded-1.14/`.

Grader-flow controls, three fresh rounds on the final bundle and the 1.18.4 image (`grade.py … r1|r2|r3`):

| Control | Submission (preservation + submitted tests) | Hidden acceptance (8) | Regression | Coverage probe | Outcome |
| --- | --- | --- | --- | --- | --- |
| Unchanged (empty patch) | 192/192 pass | completed; tests 1–7 fail in phase `test` (`ExUnit.AssertionError`), test 8 passes. The failure set equals `starting_failures` exactly. | 192/192 pass | n/a | rejected |
| Reference + reference tests | 198/198 pass | 8/8 pass | 192/192 pass | completed, rc 2. All 6 submitted tests fail in phase `test` on the baseline, and all 6 are detected. | **passed** |
| Reference + integrity | not completed (VM halts at compile) | not completed | not completed | none | rejected; executed |
| Incomplete (no index) | 192/192 pass | completed; only test 7 fails, in phase `test` (`ExUnit.AssertionError`) | 192/192 pass | n/a | rejected; fails a starting failure |

- In all three rounds every test identity, state, failure phase and failure type, plus the coverage detections, were identical (`compare_rounds.py r1 r2 r3`).
- The `valid_controls?` equivalent is true in every round, and no failure lacked its phase marker.
- These are local diagnostics, not the three controller qualification rounds.
- The bundle was unchanged between the start of the rounds and the final hashes below.

- Source reconstruction: export the baseline tree (`a868fa90`), then `git apply --index` `reference.patch`, `upstream-tests.patch` and `upstream-docs.patch`. This gives `63f6cb8b…`, which equals the reference branch tree.
- Contract check: `scripts/contract_check.exs` loads the project's own `task_contract.ex`, `grader.ex` and `provenance.ex` (pinned 1.18.4 image, `--network none`). `TaskContract.read/1` and `Provenance.validate!/2` succeed. `validate_patch` returns `{:ok, []}` for the three test patches against `test/`, and for `reference.patch`, `incomplete.patch` and `integrity.patch` against `allowed_edit_prefixes`. The appended solver instructions are in `logs/contract-check.log`.
- Diagnostics (M1, M2, M3, Alt) were re-run on the final acceptance patch with 1.18.4 (`logs/diagnostics-final.txt`); the table above shows those results.
- The earlier 1.14.2 evidence gave the same named outcomes, from three rounds plus an exploratory round before test 8 gained the `/robots` page. It is kept under `logs/superseded-1.14/`.

## Bundle hashes (sha256)

```
0a948a68c045533e5db35a1df2105e0ca5bdd1bac4e809a3a83a6a860a98134a  acceptance.patch
825847817c23c8fea9f74bba2048c31547cc8f6d25b3fb28a7ea063f5b2d6e42  case.json
6d93a34966c8a3799fbe695f85b370cf6075442d8d6f24aea3927d6cb627160e  incomplete.patch
9345cf52f8dccb1cf508da8776f27ce7317661503c16dd2710d053c7416dd193  integrity.patch
5727b867e7423a36a02791056a8c85f51ae11e83a0db4d613922eeca81d898e7  provenance.json
9c4f02b5ddbd36f00274813a8368dcb1065e391cf7d78faa86b51925b32ac6dd  reference.patch
cbde6891c17f3853efce1c2bd49db958f24c19430c4249370d256d54614a559e  reference-tests.patch
ee34802ee739c649a7fc104c2006573e50eb89b1e8018aca2e4b3bf273499bcf  ticket.md
2b22ba717becaa29cee9fbbd1545e5f5bf502ef45611ed22429bc91a3667d791  upstream-docs.patch
23952d4b472c22e6b5b3eda7228bf5d5bc1ba539d32e8d1ac14ea8df71deedf7  upstream-tests.patch
```

## Review amendments (2026-10-26)

Applied at the coordinator's request after the independent review:
1. `ticket.md` Non-goals: documentation and CHANGELOG updates are now "welcome but optional". The spec no longer mentions grading.
2. `case.json` runtime image moved from 1.14.2 / OTP 25.2 to `hexpm/elixir:1.18.4-erlang-27.3.4-ubuntu-noble-20260509.1@sha256:11ee3fe5…493c`.
3. `clarifications.environment` now says Elixir 1.18.4 / OTP 27.3.4.
4. `acceptance.patch` adds a `Code.ensure_loaded?(Beacon.Router)` guard to the router's index declaration and to the test's named macro assertion.

Kept as before, as instructed: `ERL_FLAGS=+S 4:4`, the `noindex` and generator non-goals, and `allowed_edit_prefixes`. `reference-tests.patch` keeps its original `macro_exported?`-only guard.

On the new image the following were re-run:
- the toolchain image, dependencies and assets;
- `mix format` and `mix credo` on both branches;
- the full suites on both branches;
- three control rounds;
- the four diagnostics;
- the contract check.

## Remaining gates

1. Create the fork centrally, push both branches and open the draft source-pair PR. Fix `pull_request` if it is not #1.
2. Import through `Eab.Candidates`, get an independent requirements-first review, and run three fresh qualification rounds on the controller.
3. Run two Opus 5.5 xhigh validations (ADR 0012/0013).

## Open questions for the reviewer

1. **`ERL_FLAGS=+S 4:4`.** This is needed for the test DB pool while `:booted` boots. The alternative is a preparation-commit change to `config/test.exs` `pool_size`, which is a source change.
2. **Extension scope.** The extension adds four items: no 20-page cap, XML escaping, skipping non-Beacon routers in the index, and `text/plain` robots. Tests 3, 4, 6 and 7 grade extension behaviour that upstream lacks (M1 fails them). Is that the right amount? `noindex` exclusion was left out.
3. **Shared fixture edits in the acceptance overlay.** It mounts `:host_test` on `site_b.com`, configures `EndpointSite` through `put_env`, and uses the guarded index declaration (`Code.ensure_loaded?` and `macro_exported?`). Is the guarded remote macro call acceptable under the "no new macros at compile time" rule?
4. **`allowed_edit_prefixes`** include `config/` and `.formatter.exs`, which are forced by the exact replay and natural for solvers. Also `guides/` and `CHANGELOG.md`.
5. **Generator follow-up `9dde49dc`** is out of scope. A site endpoint generated with `mix beacon.gen.site --host` still serves a static `priv/static/robots.txt` before Beacon's at the root site.
6. **Spec strictness.**
   - Is `lastmod` = published `updated_at`, and the exclusion of draft edits, too fine-grained? M2 shows it is the only check on lastmod semantics.
   - Should robots.txt have exactly one `Sitemap` line, or should listing the index as well be allowed?
7. **The preservation set** excludes `install_test.exs`. Should another touched area be included?
