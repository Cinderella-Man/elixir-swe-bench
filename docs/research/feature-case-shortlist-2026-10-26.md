# Feature-case shortlist — 2026-10-26

Discovery shortlist for the five new **feature** cases that follow Absinthe 1176 in the [rebuilt release](../adr/0012-rebuild-release-and-validate-with-unpublished-opus-runs.md). It ranks ten candidates from projects outside the current set (Plausible, Livebook, Operately, Accent, Ash, LiveBeats, and Absinthe once 1176 lands) and ends with a recommended five.

This is a research note, not an admission record. Nothing was cloned, built or tested for it. It reuses the 2026-10-18 and 2026-10-19 research and adds read-only GitHub checks made today (`gh pr view`, `gh api`): merge dates, file and line counts, merge parents, follow-up PRs and historical `mix.exs`, CI and config files. Any execution evidence cited below comes from the earlier deep dives, which name their toolchains. Every candidate still has to pass the full [curation workflow](../case-curation-loop.md), starting with a prepared branch in the user's fork.

## How candidates were judged

- **A feature, or a feature once enriched.** New behaviour that users or API callers can see. Under [ADR 0013](../adr/0013-specify-feature-cases-with-grilled-specs.md), a case may extend its upstream PR into a fuller feature that stays realistic for the project, with a curator-written reference and hidden tests. The extension must follow the project's style and pass the project's full existing suite. Each entry separates what upstream merged from what the curator would add.
- **Spec-able as a post-grilling brief.** The decided behaviour, edge cases, non-goals and the public interface that tests call can be written down without an implementation recipe. Interface names below are what the spec would name. File paths are curator notes and never go in the brief.
- **Size.** Roughly 4–20 implementation files in the enriched form, with tests counted separately.
- **Offline, deterministic tests.** ExUnit (or Node/Playwright for browser behaviour) in Docker, with PostgreSQL as the only allowed service. Embedded SQLite counts as no service.
- **Diversity and exposure.** The picks should span domains. Recent, little-known PRs are preferred to famous ones, so merge dates are given.

Every scored obligation must become a stated requirement, as [ADR 0012](../adr/0012-rebuild-release-and-validate-with-unpublished-opus-runs.md) and the [admission contract](../case-admission.md) require. The ambiguity notes below list the product decisions each brief has to settle.

## Ranked summary

Impl = substantive implementation files, excluding tests, docs, generated files and lockfiles. "Env proven" means an earlier deep dive ran the relevant tests at base plus patch. It does not mean three-round qualification.

| # | Candidate | Domain | Merged | Impl upstream → enriched | Tests added upstream | Environment | Source research |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Pinchflat [#610](https://github.com/kieraneglin/pinchflat/pull/610): download failure reporting, plus retry | Phoenix/LiveView + Ecto + Oban app | 2025-02-12 | ~11 → ~15 | 2 files | SQLite, Elixir 1.17; **env proven** | [deep-dive-pinchflat-610](new-candidates-2026-10-19/large-features/deep-dive/deep-dive-pinchflat-610.md) |
| 2 | Guardian [#748](https://github.com/ueberauth/guardian/pull/748): connection-derived secrets for verifying and issuing tokens | Auth/Plug library | 2026-08-17 | 5 → ~7 | 5 files | No services, Elixir 1.18/OTP 27 | [auth-policy-candidates](auth-policy-candidates-2026-10-18.md) |
| 3 | Cachex [#341](https://github.com/whitfin/cachex/pull/341) + [#342](https://github.com/whitfin/cachex/pull/342): named warmers, selective and synchronous warming | OTP caching library | 2024-03-24 / 03-26 | 8+2 → ~7 | 2 files | No services; **suite green on 1.20/OTP 29** | [deep-dive-cachex-341](new-candidates-2026-10-19/large-features/deep-dive/deep-dive-cachex-341.md) |
| 4 | Beacon [#687](https://github.com/BeaconCMS/beacon/pull/687) + [#700](https://github.com/BeaconCMS/beacon/pull/700): per-site sitemap, sitemap index and robots.txt | Phoenix CMS, multi-site routing | 2025-02-03 (both) | 6+3 → ~10 | 2 files + support | PostgreSQL, Elixir 1.14/OTP 25; **env proven** | [deep-dive-beacon-687](new-candidates-2026-10-19/large-features/deep-dive/deep-dive-beacon-687.md) |
| 5 | vutuv [#1759](https://github.com/wintermeyer/vutuv/pull/1759): `@`-mention suggestions and resolution, server side | Ecto-heavy social network app | 2026-08-30 | 6 Elixir (+2 JS) → ~7 | 5 files | PostgreSQL, Elixir 1.20/OTP 28; native `image` dependency | New dossier needed (reserve row in [xl-README](new-candidates-2026-10-19/xl-candidates/xl-README.md)) |
| 6 | Floki [#623](https://github.com/philss/floki/pull/623) + [#624](https://github.com/philss/floki/pull/624): `:has()`, enriched with relative selectors | HTML selector engine (data processing) | 2025-05-14 / 06-01 | 2+3 → ~5 | 2 files | No services, Elixir ≥ 1.14 | [data-serialization-candidates](data-serialization-candidates-2026-10-18.md) |
| 7 | Craftplan [#51](https://github.com/puemos/craftplan/pull/51): cancel unconsumed production batches | Ash/Postgres business app | 2026-10-07 | 5 → ~7 | 2 files | PostgreSQL 16, Elixir 1.20; **env proven** | [deep-dive-craftplan-51](new-candidates-2026-10-19/large-features/deep-dive/deep-dive-craftplan-51.md) |
| 8 | Mydia [#1072](https://github.com/getmydia/mydia/pull/1072): stream links for external players, plus revocation | LiveView media app, HTTP Range, authorization | 2026-10-07 | 10 → ~13 | 5 files | SQLite, Elixir 1.20/OTP 29, **Rust + WASM build** | [xl-mydia-1072](new-candidates-2026-10-19/xl-candidates/xl-mydia-1072.md) |
| 9 | Thousand Island [#211](https://github.com/mtrudel/thousand_island/pull/211): `handshake_timeout` | Socket-server library | 2026-08-21 | 7 → 7–8 | 2 files | No services, Elixir ≥ 1.13 | [more2-thousand_island-211](new-candidates-2026-10-19/more-candidates-2/more2-thousand_island-211.md) |
| 10 | Broadway [#289](https://github.com/elixir-broadway/broadway/pull/289) + [602931c](https://github.com/elixir-broadway/broadway/commit/602931c981d194c6e07e699ab45b6e3747cf44a0): custom batch splitting | OTP data pipeline | 2022-11-05 (+ fix 2023-01-18) | 3 → 3–4 | 1 file | No services, Elixir 1.13/OTP 24 era | [additional-project-candidates](additional-project-candidates-2026-10-18.md) |

The order weighs proven environment, spec clarity, feature completeness and exposure. Rank 1 is not a difficulty claim. One candidate per project is listed; same-project alternates appear inside the entries.

---

## 1. Pinchflat #610: download failure reporting, plus retry

**Source.** [kieraneglin/pinchflat#610](https://github.com/kieraneglin/pinchflat/pull/610), "Record and display errors related to downloading", resolves feature request [#602](https://github.com/kieraneglin/pinchflat/issues/602). Merged 2025-02-12 by the maintainer as a squash: base `fe5c00db`, merge `e7adc9d6`. The PR touches 15 files, +298/−70: about 11 implementation paths plus a migration, two test files, and the generated `priv/repo/erd.png`, which must be excluded. Tests added: `media_downloader_test.exs` (store on failure, clear on success, recovered and unrecoverable paths) and `string_utils_test.exs`. AGPL-3.0.

**Feature.** When a download fails, Pinchflat saves a readable reason on the media item and shows it on the media item page and in the source and history tables. A later successful download clears it, and existing retry and recovery behaviour is unchanged.

**Enrichment.** Make failures actionable, not just visible:
- add a **Failed** tab beside the source page's existing Pending, Downloaded and Other tabs, listing items that have a recorded error;
- add a **Retry failed downloads** source action, next to the existing `force_download_pending` and `force_redownload` actions, that enqueues downloads only for those items.

This fits the upstream design. The source tabs already come from one LiveView parameterised by a `MediaQuery` predicate, and source-level actions already enqueue download jobs. The enrichment adds one query predicate, one tab, one controller action and one route. That is a realistic finishing step for #602, and it forces the persisted error to drive queries, not only rendering.

**Public interface for the spec.**
- `MediaItem.last_error`: a nullable string, set on recoverable and unrecoverable failures and cleared on success.
- The pages that must show the error: the media item page, the source's media tables and the history table. A table row must show the reason itself (text or title attribute), not only an icon.
- The Failed tab, and which items it includes.
- The retry route, for example `POST /sources/:source_id/retry_failed`. The spec must say whether retry clears the error immediately or only on success.
- Retry enqueues `MediaDownloadWorker` jobs, observable with `Oban.Testing`.

**Test setup.** ExUnit, ConnTest and LiveViewTest with Floki. SQLite through `ecto_sqlite3`, so no service. yt-dlp is replaced by Mox and fixture scripts, and Oban runs in testing mode. Elixir `~> 1.17`. The deep dive ran `elixir:1.17-otp-27` in Docker: base plus patch compiled, and 8 + 29 tests passed offline once dependencies were fetched. Deterministic, with no timers.

**Risks.**
- *Grading gap:* upstream has no UI tests. Curator LiveView checks for all three pages, and for the omitted section when there is no error, are mandatory; without them a "persist-only" partial passes.
- *Ambiguity:* whether a failed but still pending item appears under both Pending and Failed. Whether a non-binary error must be rendered with `inspect`; accept any readable non-empty string.
- *Exposure:* Pinchflat has about 5k stars, but this PR is unremarkable.
- *Environment:* SQLite is fine for the runner, but the runner's preparation has only handled PostgreSQL and ClickHouse services before. Confirm the `exqlite` native build in the prepared image.
- AGPL notice in provenance.
- Same-project alternates: [#640+#641](new-candidates-2026-10-19/large-features/deep-dive/deep-dive-pinchflat-640.md) cookie policy (only valid as a combined lineage) and [#282](new-candidates-2026-10-19/xl-candidates/xl-pinchflat-282.md) YouTube API indexing (13 implementation files).

## 2. Guardian #748: connection-derived secrets for verifying and issuing tokens

**Source.** [ueberauth/guardian#748](https://github.com/ueberauth/guardian/pull/748), "select the verifying secret from the connection", closes [#690](https://github.com/ueberauth/guardian/issues/690). Merged 2026-08-17 as a squash: parent `4073c734`, merge `b1a7c817`. The PR touches 13 files, +771/−11. Five are implementation files: `plug.ex`, `verify_header.ex`, `verify_session.ex`, `verify_cookie.ex` and `token/jwt.ex`. The rest are a CHANGELOG entry, a new guide, documentation registration in `mix.exs`, and five test files (+489). MIT.

**Feature.** The `:secret` option on the header, session and cookie verify plugs may be a one-argument function of the connection, resolved per request, only when a token is present, and surviving compiled Plug pipelines. An explicit secret that is or resolves to `nil` fails closed with `:secret_not_found` instead of silently using the application secret; an omitted option keeps the old fallback, and MFA tuples keep their old meaning.

**Enrichment.** Extend the same connection-derived secret to the **issuing** side: `Guardian.Plug.sign_in/5`, `remember_me/5`, `remember_me_from_token/5` and `Guardian.Plug.SlidingCookie`, which re-issues cookies. A tenant's tokens are then signed and verified with that tenant's key end to end. The PR body names the gap itself: an implementation module may handle "both third party and self issued tokens". Without this, a self-issuing multi-tenant app still signs with a static secret, or re-issues a sliding cookie under the global key. The extension reuses the PR's resolver and its fail-closed `nil` rule, so it is one coherent feature rather than two.

**Public interface for the spec.**
- The `secret:` option shapes: static value, `{m, f, a}`, and a one-argument function. A function of any other arity raises `ArgumentError`.
- `Guardian.Plug.resolve_secret/2` stays public for custom plugs.
- Error reason `:secret_not_found` reaches the error handler.
- `sign_in`, `remember_me`, `remember_me_from_token` and SlidingCookie accept the same option.
- Refresh-from-cookie options stay separate from the initiating plug's options.

**Test setup.** Plain ExUnit, with keys, connections and cookies generated locally. No database, browser or identity provider. The parent's `.tool-versions` selects Elixir 1.18.4/OTP 27.3.4, and the lockfile pins Plug 1.19.2 and JOSE 1.11.12. Deterministic. Not executed by any earlier pass.

**Risks.**
- *Ambiguity:* whether issuing with a resolver that returns `nil` must fail; it should, for symmetry, and the spec must say so. Error-handler reason naming must be stated. Signing-side behaviour has no upstream reference, so the curator writes it and an independent reviewer should check it.
- *Exposure:* low. Guardian is well known, but this PR is recent and narrow. Its strongest check signs a token with the *global* key and expects rejection when the resolver returns `nil`; a token already invalid under the global key would not distinguish the faulty fallback.
- *Environment:* small, but unexecuted.

## 3. Cachex #341 + #342: named warmers, selective and synchronous warming

**Source.**
- [whitfin/cachex#341](https://github.com/whitfin/cachex/pull/341), "Allow warmers to be have named processes", fixes #334. Merged 2024-03-24 as three linear commits, `b22cb1ff` → `e700e966`. 10 files, +127/−87: 8 implementation files and 2 test files.
- [#342](https://github.com/whitfin/cachex/pull/342), "Add a new :wait option to control Cachex.warm/2". Merged 2024-03-26 with parent `e700e966`, so the two PRs form an **adjacent upstream interval** and need no synthetic tree. 3 files, +91/−31: `cachex.ex`, `actions/warm.ex` and `warm_test.exs`.
- MIT.

**Feature.** A warmer spec may carry an optional process `name`, so several warmers built from one module can be supervised and addressed without colliding. `Cachex.warm/2` can warm only selected warmers by module or name, and can optionally block until warming finishes instead of returning straight away.

**Enrichment.** Combining the two upstream PRs is the enrichment: one coherent capability for controlling manual warming. A further curator addition is optional: make `warm/2` report which warmers it actually ran, so callers can see the effect of `only:`. #343 (renaming async flags to `required`) stays out, because it is a separate API redesign.

**Public interface for the spec.**
- `warmer(module: …, name: …)`: the name is `nil` or an atom, and an invalid name fails `Cachex.start_link` validation.
- `Cachex.warm(cache, only: [module_or_name, …], wait: boolean)`, with the return shape stated.
- Unnamed warmers behave as they do today.
- Full-cache warming and periodic warming are unchanged.

**Test setup.** ExUnit, ETS only, no services. The `test` alias starts `epmd` for `local_cluster`, but the warm tests are single-node. Elixir `~> 1.5` is declared and CI images go up to `elixir:1.16`. **There is no committed `mix.lock`**, so dependencies must be pinned during preparation. The deep dive ran 15 targeted and 200 full-suite tests green on Elixir 1.20.4/OTP 29; the era toolchain was not tried. The synchronous mode is deterministic through call semantics, and no sleeps are needed.

**Risks.**
- *Exposure:* moderate. Cachex 4 documents the end-state API (`name`, `only`, `wait`), and the PRs date from 2024.
- *Ambiguity:* the `only:` semantics for a module whose instances are named (does the module match all of them?), and what the call returns. The spec must settle both.
- *Environment:* part of #341 is an internal refactor (common linking moved into `Services`, Informant shrunk). Do not require it; grade the public API only.
- [#306](new-candidates-2026-10-19/large-features/large-feature-cachex-2.md) (scheduled LRW, timing-based) and [#353](new-candidates-2026-10-19/xl-candidates/xl-cachex-1.md) (routers, 14 implementation files) stay reserves.

## 4. Beacon #687 + #700: per-site sitemap, sitemap index and robots.txt

**Source.**
- [BeaconCMS/beacon#687](https://github.com/BeaconCMS/beacon/pull/687), "generates `sitemap.xml` per site and a `sitemap_index.xml`", resolves [#169](https://github.com/BeaconCMS/beacon/issues/169). Merged 2025-02-03 as a squash: base `86c9ffd2` (the first parent, **not** the dossier's older `78c0fef0`), merge `1aa11357`. 15 files, +235/−18: 6 implementation files plus formatter, config and CHANGELOG changes, 2 test files and 4 support files.
- [#700](https://github.com/BeaconCMS/beacon/pull/700), "generates `robots.txt` per site". Merged 25 minutes later by the same author with parent `1aa11357`, so the pair is an **adjacent upstream interval**. 6 files, +56/−2: 3 new implementation files, a router edit and 1 test.
- MIT.

**Feature.** Each Beacon site serves a `sitemap.xml` of its published pages (location plus last-modified time) and a `robots.txt` that points crawlers at the sitemap. A `sitemap_index.xml` lists every running site's sitemap. URLs must use the right host and path prefix for each site, including sites mounted under a scoped prefix.

**Enrichment.** Joining #700 to #687 makes one "crawler discovery" feature. One optional, realistic curator addition: leave out pages whose meta tags declare `robots` `noindex`. Beacon pages already carry per-page meta tags, and listing a noindex page in a sitemap is a known SEO contradiction. This touches the page query, not only the templates. Do **not** back-port the later URL-placement redesign (#740, #746, #749): it moved the index and robots.txt to the proxy host one week later, and is a different product decision.

**Public interface for the spec.**
- The routes `…/sitemap.xml`, `…/robots.txt` and `/sitemap_index.xml`, relative to the `beacon_site` mount.
- XML namespaces and elements (`urlset`/`url`/`loc`/`lastmod`, `sitemapindex`/`sitemap`/`loc`).
- Content types.
- Which pages are included: published pages only, plus the noindex rule if adopted.
- The ordering rule for index entries.
- The cache header, only if graded.

**Test setup.** ExUnit ConnTest against two test endpoints and routers. PostgreSQL 15. Preparation must install the esbuild and tailwind CLIs (`mix esbuild.install`, `mix tailwind.install --no-assets`), because `Beacon.Boot` refuses to start without them. The deep dive ran this on `elixir:1.14-otp-25`: 2 sitemap tests and 4 preservation tests passed at base plus patch. Deterministic.

**Risks.**
- *Ambiguity:* the exact `lastmod` format (the reference uses ISO-8601 from `updated_at`); index ordering (the reference sorts); text whitespace in templates. Parse the XML rather than comparing bytes.
- *Environment:* the two CLI binaries must be cached at preparation time.
- *Exposure:* low (niche CMS, early 2025).
- Same-project reserve: [#578](new-candidates-2026-10-19/xl-candidates/xl-beacon-578.md), site-wide `handle_info` callbacks across 14 implementation files with hot reload.

## 5. vutuv #1759: `@`-mention suggestions and resolution, server side

**Source.** [wintermeyer/vutuv#1759](https://github.com/wintermeyer/vutuv/pull/1759), "suggest @-mentions while typing, and show them as chips", closes #1748. Merged 2026-08-30 as a squash: parent `a4403734`, merge `f24cc11d`.
- 19 files, +3414/−1731. Most of that is noise: four gettext catalogs (about 1,700 lines of churn), 2 JS files, CSS and a docs page.
- 6 Elixir implementation files: `mentions.ex`, `mention_controller.ex`, `markdown.ex`, `router.ex`, `ui.ex` and `post_live/composer.ex`.
- 5 test files, including `mention_resolution_agreement_test.exs`.
- The PR body says an AI agent wrote its text; record that as exposure metadata. MIT.

**Feature.** While a member types `@`, the app offers matching members and public organization pages. The ranking is followed accounts first, then handle-prefix matches before name matches, then alphabetical. It never offers accounts blocked in either direction, hidden or unconfirmed members, non-public pages, or the viewer. A companion check reports which handles in a draft will actually render as links, using exactly the renderer's resolution, so the composer cannot promise a link that never appears.

**Enrichment.** Keep the JavaScript picker as a stated **non-goal**: grading it would need Playwright and adds little Elixir work. In its place, add the LiveView-native half of the same user problem. The post composer flags, on change, any `@handle` in the draft that will not resolve, using the same resolution as the check endpoint, *before* the save refuses it. The PR describes exactly that gap: the first sign of a wrong handle "was the save being refused". The enrichment keeps one resolution path shared by the renderer, the endpoint, the save validation and the live warning, which is the cross-component consistency worth testing.

**Public interface for the spec.**
- `GET /system/mentions/suggest?q=` returns `{results: [{kind, handle, name, avatar, initials}]}`.
- `GET /system/mentions/check?handles=a,b` returns `{known: [...], checked: [...]}`.
- Both require a signed-in member.
- `Vutuv.Mentions.suggest/3` and `check_handles/1`.
- Product constants: minimum 2 characters, 8 results, at most 50 handles checked.
- The live warning's visible text or marker in the composer.

**Test setup.** ExUnit, ConnTest and LiveViewTest (`lazy_html`) on PostgreSQL. The `test` alias runs `ecto.create` and `ecto.migrate`. `config/test.exs` disables fediverse, screenshot, email and other external workers. `.tool-versions` selects Elixir 1.20.0-otp-28 and Erlang 28.5. Deterministic: ranking can be tested with fixed fixtures.

**Risks.**
- *Environment, unexecuted:* the `image` dependency pulls in a libvips NIF through `vix`, and `ex_cldr`, `tz` and `ex_phone_number` carry data that must be present offline. All of it must be fetched into the prepared image. No earlier pass ran this app.
- *Ambiguity:* the ranking tie-breaks and the 24-candidate pool cap. The reference can drop a followee past 24 name matches. Either state the cap or keep fixtures under it.
- *Exposure:* low (recent, small project).
- Needs a dossier before preparation.

## 6. Floki #623 + #624: `:has()`, enriched with relative selectors

**Source.**
- [philss/floki#623](https://github.com/philss/floki/pull/623), parsing by the maintainer. Merged 2025-05-14 (`4d92b013`): 3 files, +102/−29, of which 2 are implementation files (`parser.ex`, the leex lexer).
- [#624](https://github.com/philss/floki/pull/624), matching. Merged 2025-06-01 (`f900ea1e`) with #623 as its immediate parent: 5 files, +419/−43, of which 3 are implementation files (`selector.ex`, `parser.ex`, `pseudo_class.ex`), plus the README and `floki_test.exs` (+353).
- Base `be2b265c`. Answers issue #482. MIT.

**Feature.** `Floki.find/2` supports `E:has(…)`, selecting elements that have a matching descendant. Comma-separated alternatives inside one `:has` mean OR, and chained `:has` clauses mean AND.

**Enrichment.** Upstream supports only simple selectors inside `:has`. Its own tests comment out `th:has(> label)`, `tr:has(td + td)`, `tr:has(div:has(label))` and `tr:not(:has(label))` as unsupported. The enrichment finishes the pseudo-class:
- relative selectors (`> x`, `+ x`, `~ x`);
- complex inner selectors (`div label`);
- nesting inside `:not`;
- compound inner selectors such as `[data-x].marked`, which the [data report](data-serialization-candidates-2026-10-18.md) suspects the shared parser splits.

Floki's later history (to 2026-09) never added these, so the curator writes the whole reference. Semantics come from CSS Selectors Level 4 relative selectors: objective, well documented, and testable through the public API alone.

**Public interface for the spec.**
- `Floki.find/2` and `Floki.Selector` parsing results for the supported syntax.
- An explicit list of supported and unsupported forms. Nested `:has` inside `:has` is invalid per spec; state the outcome.
- Document order with no duplicates when several descendants match.
- Behaviour on parse errors (ignored or raised, matching existing Floki behaviour).

**Test setup.** ExUnit, no services, pure functions. Elixir `~> 1.14`; CI covered 1.18/OTP 27.2 and 1.14/OTP 24.2. Pin the Mochiweb parser. The test helper's parser tags must not silently exclude required checks, and optional fast_html and html5ever native parsers must not be needed. Fully deterministic.

**Risks.**
- *Reference correctness:* the enriched part has no upstream implementation. It needs an independent review against the CSS specification and a few browser-verified examples recorded as fixtures.
- *Overlap:* lexer and parser work resembles Absinthe 1176's grammar work, so this is the weakest diversity pick of the top six.
- *Exposure:* low for the enriched part.

## 7. Craftplan #51: cancel unconsumed production batches

**Source.** [puemos/craftplan#51](https://github.com/puemos/craftplan/pull/51), "allow canceling unconsumed batches", fixes [#47](https://github.com/puemos/craftplan/issues/47). Merged 2026-10-07 as a squash: base `ad9fb484`, merge `46c0a6fa`. 8 files, +157/−5: 5 implementation files (an Ash change module, the batch resource, the domain, batching, the LiveView), a docs page, and 2 test files with four new tests. AGPL-3.0.

**Feature.** An open or in-progress production batch with no recorded consumption can be canceled from its page. This releases its order allocations for re-planning without deducting inventory, and the batch can then no longer be started, consumed or completed. Completed or consumed batches reject the cancel.

**Enrichment.** Record a required cancellation reason and the time of cancellation. Show both on the batch page, and make the existing Canceled filter list canceled batches with their reason. This is realistic for a production-planning tool and stays within the batch lifecycle. It adds attributes to an Ash resource, so preparation must handle `ash_postgres` codegen output (a migration and resource snapshots) as generated files.

**Public interface for the spec.**
- The Ash action names (or the LiveView event) the tests call.
- The batch statuses involved.
- What "consumption recorded" means.
- The rejection error type.
- The reason field's validation (required, maximum length).

**Test setup.** ExUnit domain tests and LiveViewTest on PostgreSQL 16. Elixir `~> 1.20`, with native `bcrypt_elixir` and `picosat_elixir` and a cached Heroicons git dependency. The deep dive ran 9 + 15 tests green at base plus patch. Deterministic.

**Risks.**
- *Overlap:* Craftplan is a new project but is built on Ash, which Ash 3031 already covers. This is why it ranks below #6.
- The upstream feature is small (5 implementation files) without the enrichment.
- AGPL notice in provenance.

## 8. Mydia #1072: stream links for external players, plus revocation

**Source.** [getmydia/mydia#1072](https://github.com/getmydia/mydia/pull/1072). Merged 2026-10-07 as a **true merge**: first parent `423921b9`, merge `a60ce87c`. 15 files, +588/−49: 10 implementation files (token module, stream-link controller, shared Range helper, the API stream controller, router, four LiveView/HEEx files, a JS clipboard hook) and 5 test files. Follow-up [#1075](https://github.com/getmydia/mydia/pull/1075) (same day) reworks only the file-row UI. AGPL-3.0.

**Feature.** Every movie or episode file row offers a durable stream URL for VLC, mpv or Infuse. The URL serves the raw file with byte ranges (200, 206 or 416), even when the in-app player is disabled. Access is re-checked on every request: a tampered token, trashed file, deleted user, newly restricted library or missing file all return a uniform 404.

**Enrichment.** Add **revocation**: a member can reset their stream links, which invalidates every link issued before the reset. Without it, the only way to revoke a leaked durable link is to rotate `secret_key_base`. The enrichment needs a persisted per-user link generation (a migration), a check of that generation during per-request re-authorization, and an account-settings action. It builds on the PR's own invariant that authorization is re-evaluated on every hit.

Same-project alternate: [#1112](new-candidates-2026-10-19/large-features/deep-dive/deep-dive-mydia-1112.md), "disable library indexers without removing them" (merged 2026-10-11, 10 implementation files including a backfill migration). It is the more Ecto-heavy Mydia option. A later upstream `CardigannLibrary.configure/2` could be its enrichment.

**Public interface for the spec.**
- The link path shape, with the token as the only authority and the filename decorative.
- The 404 policy.
- Range semantics: 206 with `content-range`, and 416. State the suffix-range rule or leave it unscored.
- `cache-control: private, no-store`, if graded.
- Where links appear; tests follow the rendered `href`.
- The reset action and its effect.

**Test setup.** ExUnit, ConnTest and LiveViewTest with real temporary files. SQLite by default; PostgreSQL is selected with `DATABASE_TYPE`. Elixir 1.20 and OTP 29 (`.elixir-version`, `.otp-version`; the Dockerfile uses `hexpm/elixir:1.20.4-erlang-29.1`). Deterministic, with no network.

**Risks.**
- *Environment, newly found today:* `mix compile` builds a **Rustler NIF for iroh peer-to-peer networking** (`native/mydia_p2p`) and runs a custom `:plugins` compiler that builds **WASM plugin guests with cargo for `wasm32-wasip2`**. `wasmex` adds a precompiled wasmtime NIF. Preparing it offline means a pinned Rust toolchain with the WASM target and vendored crates. That is far heavier than earlier research assumed ("Elixir 1.20 unproven"), and it applies to every Mydia candidate, including #1112 and #1119.
- *Ambiguity:* the earlier grilling found that the dossier's incomplete control is wrong. Use "authorize only when minting" instead.
- *Exposure:* low, since the PR is days old. The repository contains `CLAUDE.md`, `AGENTS.md` and `GEMINI.md`, which signal agent-assisted development.

## 9. Thousand Island #211: `handshake_timeout`

**Source.** [mtrudel/thousand_island#211](https://github.com/mtrudel/thousand_island/pull/211). Merged 2026-08-21 as a squash: parent `8c319973`, merge `a2858bbe`. 9 files, +189/−5: 7 implementation files (server option docs, `ServerConfig`, `HandlerConfig`, `Socket`, the `Transport` behaviour, SSL and TCP transports) and 2 test files. MIT.

**Feature.** A new `handshake_timeout` server option (default 5000 ms, `:infinity` for unbounded) bounds a transport handshake such as TLS negotiation. A stalled client is closed and reported to `handle_error/3` with `:timeout`. Transports that implement only the existing `handshake/1` callback keep working.

**Enrichment.** Not needed for size, since the PR already has 7 implementation files across config, behaviour and transports. A possible addition is to expose the handshake-timeout outcome through the library's existing connection telemetry span. Verify that span's metadata before proposing it.

**Public interface for the spec.**
- The `:handshake_timeout` option, its default, and `:infinity`.
- The optional `c:ThousandIsland.Transport.handshake/2`.
- The `handle_error/3` reason `:timeout`.
- `read_timeout` stays distinct.

**Test setup.** ExUnit with loopback TCP/TLS using repository certificates. No services. Elixir `~> 1.13`, with CI through a shared workflow. Deterministic only if waits are bounded: a stalled client with a small timeout and `assert_receive` with a generous deadline, never sleep-then-assert.

**Risks.**
- *Timing:* the behaviour is inherently a timeout. The assertion waits for an event and does not measure time, but slow shared hosts make it the riskiest candidate here under this repository's no-timing rule.
- Upstream CI automatically re-runs failed jobs up to three times, which hints at tolerated flakiness in the suite.
- Same-project alternate: the [#206+#208+#209 acceptor-resilience lineage](new-candidates-2026-10-19/more-candidates-2/more2-thousand_island-206-208-209.md) is a bug fix, not a feature.

## 10. Broadway #289 + correction 602931c: custom batch splitting

**Source.** [elixir-broadway/broadway#289](https://github.com/elixir-broadway/broadway/pull/289). Merged 2022-11-05: parent `45ee6bf6`, merge `cfb81170`. 4 files, +338/−50: 3 implementation files (`broadway.ex`, `options.ex`, `topology/batcher_stage.ex`) and `broadway_test.exs` (+203). Follow-up timer-lifecycle correction [602931c](https://github.com/elixir-broadway/broadway/commit/602931c981d194c6e07e699ab45b6e3747cf44a0) (2023-01-18) changes only `batcher_stage.ex` (+22/−28). The two patches apply in sequence (text check in the 2026-10-18 report), but they are not adjacent upstream, so the reference is a synthetic tree. Apache-2.0.

**Feature.** A batcher's `batch_size` may be `{initial_acc, splitter}`, where the splitter returns `{:emit, acc}` or `{:cont, acc}`, so batches can be split by content such as byte size. Each batch starts from the initial accumulator, batch keys stay isolated, and an explicit `max_demand` is required.

**Enrichment.** Include the timer correction as part of the stated contract: a stale timeout from an already-emitted batch must not flush or crash a replacement batch with the same key. Even with it, the case stays at 3–4 implementation files, at the bottom of the size range.

**Public interface for the spec.**
- The `batch_size` forms and splitter arity and return values.
- The `max_demand` requirement and the rejection of invalid configuration.
- `BatchInfo.size` and `batch_mode` reasons.

**Test setup.** ExUnit with an in-test manual producer. No services. Elixir `~> 1.7`; historical CI ran 1.13.3/OTP 24.2.1. The upstream feature tests are deterministic, but the timer-correction witness needs a constructed mailbox state, which is hard to make deterministic. The 2026-10-18 report says sleeps are not acceptable for it.

**Risks.**
- *Exposure:* high. This is a 2022 feature documented in Broadway's public docs.
- Size is borderline.
- The provenance is a composite synthetic tree.

---

## Recommended five

Chosen to span the requested kinds of work with one case per project. Together they add three applications and two libraries to a release that is currently app-heavy, with sizes from about 7 to about 15 implementation files.

1. **Guardian #748, enriched (library: auth/Plug).** It adds request-dependent security configuration with a sharp fail-closed rule across five entry points, needs no services, and is too recent to be memorized.
2. **Pinchflat #610, enriched (Phoenix/LiveView app with Ecto and Oban).** Its persisted failure state must drive a pipeline, three pages, a query-backed tab and a retry job, and it is the only app candidate whose exact environment already ran green offline.
3. **Cachex #341 + #342 (OTP library).** It brings supervision, process naming and synchronous control of background work into the release from a clean adjacent upstream interval, with the suite already green on a modern toolchain.
4. **vutuv #1759, server side plus live validation (Ecto-heavy app).** Ranking and exclusion queries over follows, blocks, moderation and visibility must agree with the renderer, in a social-network domain the benchmark lacks, from a PR merged in August 2026.
5. **Beacon #687 + #700 (Phoenix CMS, multi-site routing).** URL generation must stay correct across hosts, scoped prefixes and three crawler-facing outputs, from an adjacent upstream interval whose environment is already proven.

**Swap rules.**
- If vutuv's native dependencies (`image`/vix, CLDR data) will not prepare offline, replace it with **Craftplan #51**.
- If the maintainer wants a small, pure data-processing task instead of a third app, replace Beacon with **Floki :has**.
- **Mydia #1072** is the strongest LiveView feature on paper, but should wait until a Rust/WASM preparation recipe exists.

## Considered and not shortlisted

These are candidates the maintainer may expect, with the reason each stays out of the ten.

| Candidate | Why not |
| --- | --- |
| Mydia [#1119](https://github.com/getmydia/mydia/pull/1119): TV metadata provider fallback (the 2026-10-19 "pilot first" large feature) | 30 files, +1493/−522, including about 600 lines of LiveView modal extraction that is refactoring, not feature work. It also carries Mydia's Rust/WASM build. #1072 is the cleaner Mydia representative. |
| Absinthe [#1404](https://github.com/absinthe-graphql/absinthe/pull/1404), the [#1386 OneOf lineage](new-candidates-2026-10-19/more-candidates/more-absinthe-1386-1438-1439.md) | Same project as the chosen Absinthe 1176. OneOf also has an unresolved conflict with the specification. |
| Bandit [#707](https://github.com/mtrudel/bandit/pull/707): chunked compression (merged 2026-10-12) | Fresh and attractive, but only 3 implementation files. The central zstd path needs OTP 29 and the codec fallback needs a second runtime. Upstream tests assert exact compressed sizes and a telemetry duration bound, so the checks would need rewriting. |
| Phoenix.PubSub [#209](https://github.com/phoenixframework/phoenix_pubsub/pull/209) / [#218+#219+#220](https://github.com/phoenixframework/phoenix_pubsub/pull/218) | 2–3 implementation files. #209's dispatcher option was deprecated by #218 within six months. #218's distributed tests need peer nodes. Phoenix-family exposure. |
| Phoenix [#6871](https://github.com/phoenixframework/phoenix/pull/6871): `max_channels_per_transport` | 2 implementation files, in Phoenix core. |
| ecto_sql [#703](https://github.com/elixir-ecto/ecto_sql/pull/703): MyXQL `insert_mode` | Renamed from `:ignore_errors` to `:ignore` the next day. Its integration behaviour needs MySQL, which is outside the PostgreSQL-only rule. Most of the six paths are one-line adapter callback changes. Ecto-family exposure. |
| Oban [#347](https://github.com/oban-bg/oban/pull/347): dynamic repos | 2020 toolchain (Elixir 1.10/OTP 23) and a famous project. |
| Cachex [#353](https://github.com/whitfin/cachex/pull/353) / [#306](https://github.com/whitfin/cachex/pull/306) | #353 has 14 implementation files and a ring-routing remap bound that is not settled. #306 is timing-based eviction. #341+#342 is the Cachex pick. |
| Broadway [#344](https://github.com/elixir-broadway/broadway/pull/344): config storage | Motivated by performance. Its upstream test breaks suite isolation (`put_env(…, nil)`), and it needed two follow-up fixes. |
| Redix [#351](https://github.com/whatyouhide/redix/pull/351): least-busy cluster routing | A 518/−408 rewrite with an empty PR body. The outcome is load distribution, which edges towards a performance claim. |
| Explorer [#1138](https://github.com/elixir-explorer/explorer/pull/1138): `nulls_equal` joins | Needs an offline Rust/Polars build, and must load the *submitted* NIF rather than a prebuilt one. |
| TeslaMate [#5543](https://github.com/teslamate-org/teslamate/pull/5543): Home Assistant MQTT discovery (merged 2026-08-14) | Most of the work is one 576-line module of entity definitions. A fair spec would have to list dozens of payload choices (topics, units, device classes), which is hidden-policy risk. Kept as a reserve for an IoT slot. |
| NervesHub [#3117](https://github.com/nerves-hub/nerves_hub_web/pull/3117): org webhooks | 52 files, and needs ClickHouse beside PostgreSQL. |
| Livebook [#2608](https://github.com/livebook-dev/livebook/pull/2608): runtime proxy | Livebook is already covered, and the 2026-10-19 grilling put it on hold. |
| Changelog.com [#201](https://github.com/thechangelog/changelog.com/pull/201): JSON Feed | 2018 toolchain. The licence is non-standard. |
| LiveDashboard [#487](https://github.com/phoenixframework/phoenix_live_dashboard/pull/487), Ueberauth [#217](https://github.com/ueberauth/ueberauth/pull/217) | One implementation file each. |
| AshAuthentication [#1187](https://github.com/team-alembic/ash_authentication/pull/1187) | Needs a real browser witness, and is Ash-family. |
| Mobilizon !1378 | Hosted on Framagit; source provenance there is unsupported. |

## New evidence from today's checks

- **Mydia builds Rust and WASM during `mix compile`.** A Rustler NIF (`native/mydia_p2p`, iroh) and a custom `:plugins` compiler targeting `wasm32-wasip2` are part of every Mydia build. Previous research did not record this. It raises preparation cost for all Mydia candidates.
- **Two lineages are adjacent upstream intervals.** Beacon #700's parent is #687's merge, and Cachex #342's parent is #341's last landing commit. Both can use real upstream trees and need no synthetic composite.
- **Floki never added relative `:has` selectors upstream** (history checked to 2026-09-23). The enrichment is therefore genuinely curator-authored.
- **Guardian #748 covers only verification.** `sign_in`, `remember_me` and `SlidingCookie` still use static secrets at the merge commit, which is the gap the proposed enrichment fills.
- **Pinchflat's source page already builds its tabs from `MediaQuery` predicates,** and already has bulk download actions. The Failed tab and retry enrichment follows existing patterns rather than inventing a new UI.

## Next steps for whichever five are chosen

For each pick:
1. Write the dossier.
2. Grill and freeze the brief, keeping its decisions separate from the reference.
3. Prepare the fork baseline and reference branches following [prepared fork sources](../prepared-fork-sources.md).
4. Write curator tests for every enriched obligation.
5. Run unchanged, reference, incomplete and integrity controls in three fresh rounds.
6. Get an independent contract review.
7. Run two Opus validation attempts, per ADR 0012.

Do vutuv's and Guardian's environment proofs first, because neither project has run any tests here yet.

ADR 0013 requires each extension to pass the project's **full** existing suite. The earlier deep dives ran only targeted files for Pinchflat, Beacon and Craftplan. Cachex is the one project whose full suite has run, on Elixir 1.20/OTP 29 only. A full-suite baseline, with any pre-existing failures recorded, is therefore part of each project's first preparation step.
