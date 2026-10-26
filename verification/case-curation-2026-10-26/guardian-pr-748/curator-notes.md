# guardian-pr-748: curator notes

Status: **unadmitted draft, revision 2** (2026-10-26). The independent reviewer approved revision 1, and revision 2 applies four curator-requested precision fixes (see "Revision 2" below). Nothing is pushed, imported, reviewed or qualified through `Eab.Candidates` yet. No model runs. These notes are curator-side only and are kept outside the bundle.

## Source

| Item | Value |
| --- | --- |
| Upstream | ueberauth/guardian#748, "select the verifying secret from the connection". Closes #690. MIT. |
| Upstream merge | `b1a7c817da9ca6df88fb8617f174d72ecc656c79` (squash, 2026-08-17, author Yordis Prieto). Tree `91428048…`. |
| Upstream parent | `4073c734421cb87f173b666d6e828e273cff6a4d`. Tree `78aaa473…`. |
| Local clone | `.local/new-cases/repos/guardian` (full clone of upstream, `master` at `6e86224`) |
| Baseline branch | `codex/guardian-pr-748-benchmark` = `c251a21ca813bb1efebf8e7ab28b39fbc11fc854`, tree `03824992…` (parent plus one neutral preparation commit) |
| Reference branch | `codex/guardian-pr-748-reference` = `297172d2430dfc24b2e2d80f931ccc34171f7dad`, tree `ac9a7cd2…`. Revision 1's tip `830ac06` (tree `1ee0cdc8…`) is superseded by a docs-only amend. |
| Upstream replay | `18399a57620d4ea3541323647cc8e51e8017cdae`. The author is kept, and `git patch-id --stable` equals upstream's (`f21daf4b…`). Replaying it onto the unprepared parent gave exactly the upstream tree `91428048…`. This was checked before the preparation commit existed. |
| Curator extension | `297172d2…` (amended from `830ac063…`; the difference is `CHANGELOG.md` and the guide only), parent `18399a5…` |
| Target fork | `https://github.com/Cinderella-Man/guardian`. It does not exist yet. The branches and the source-pair PR are unpublished. `provenance.json` assumes the draft PR will be **#1**, so correct it if not. |

Follow-ups checked: `a9c9838` (v2.5.0 release, changelog only) and `6e86224` (docs formatter). Neither touches the feature, so neither is absorbed.

## What upstream changed (5 implementation files)

- `Guardian.Plug.resolve_secret/2` (new, public). A one-argument `:secret` function is called with the conn. Any other function arity raises `ArgumentError`. Everything else is left untouched, and an explicit `nil` is kept.
- `VerifyHeader` and `VerifySession` resolve after a token is found and before `decode_and_verify`. `VerifyCookie` resolves before `Guardian.exchange`, which both verifies the cookie and signs the new token.
- `Guardian.Token.Jwt` default `SecretFetcher`: an explicit `:secret` that is or resolves to `nil` now gives `{:error, :secret_not_found}`. Only an absent `:secret` falls back to `:secret_key`. `decode_token/3` propagates `:secret_not_found` instead of collapsing it into `:invalid_token`.
- `mix.exs` registers the new guide. CHANGELOG and `guides/plug/runtime-secrets.md` are documentation.

Upstream did not touch issuing. At the merge, `sign_in`, `remember_me`, `remember_me_from_token` and `SlidingCookie` pass a function `:secret` straight to JOSE. Signing crashes with `FunctionClauseError` in `:jose_jwk.from/1`. `SlidingCookie` swallows the verification error (`decode_and_verify` rescues it), so it never re-issues.

## Curator extension (decided design)

- `sign_in/5` resolves once before `Guardian.encode_and_sign`. `after_sign_in`, the session write and the error handler keep the caller's original opts, as in the upstream verify plugs.
- `remember_me/5` resolves before `encode_and_sign`.
- `remember_me_from_token/5` resolves once and uses the result for both `decode_and_verify` and `exchange`.
- `SlidingCookie` resolves once, after the cookie token and sliding window are found and before `decode_and_verify`. It passes the resolved opts to `remember_me/5`, which is then a no-op re-resolve. The `sliding_cookie/3` callback keeps the original opts.
- Docs: moduledocs (`Guardian.Plug`, `remember_me`, new `remember_me_from_token` doc, `SlidingCookie` options), a new "Issuing tokens with a per request secret" section in the guide, an updated secret-fetcher paragraph, and a CHANGELOG entry. Revision 2 states the exact handler reason, `{:unauthenticated, {:error, :secret_not_found}}`, in the CHANGELOG and the guide, and documents that `sign_out/3` needs a fixed secret for tenant tokens.
- Checks: format clean, `mix credo` clean (as on baseline). The full suite passes on the reference branch.

### Fail-closed rule (decision)

"Cannot be resolved" means the explicit `:secret` is `nil` or resolves to `nil`. A resolver exception is a separate case: it propagates.

| Surface | Outcome |
| --- | --- |
| Verify plugs | Error handler gets `{:invalid_token, :secret_not_found}`. The conn is halted per `:halt`, and nothing is stored on the conn (upstream). |
| `sign_in` / `remember_me` / `remember_me_from_token` | Nothing issued: no token on the conn, no session token, no cookie. They use the existing reporting path, `handle_unauthenticated`: error handler `{:unauthenticated, {:error, :secret_not_found}}` and halt, or `Guardian.Plug.UnauthenticatedError` without a handler. Since revision 2, the spec and tests require exactly this shape, which the reference emits. |
| `SlidingCookie` | Request unchanged: no cookie, no handler call, not halted. It never re-signs with `:secret_key`. This matches its documented "no errors are handled" behaviour. |
| Guardian token API | `{:error, :secret_not_found}` (upstream Jwt rule) |
| Resolver raises | Propagates (upstream `resolve_secret` semantics). It is not an auth error and never a fallback. |

The rule lives in the token module, as upstream decided: the plug passes `nil` through, and `Guardian.Token.Jwt`'s default fetcher refuses it. A custom `secret_fetcher` receives `nil` and decides for itself. The spec states this only as "custom fetchers receive the resolved value".

### Scope decisions

- **The function form in `sign_out/3` is a non-goal.** Revocation verifies, and with a `nil` secret the existing `sign_out` error path would *refuse to sign out*, which is not a clean fail-closed story. Revision 2 rewords the non-goal so it no longer reads as conflicting with the `revoke` row of the Guardian API table: revocation with static, `{m, f, a}` or `nil` secrets behaves as specified. Solvers may still support the function form.
- Probe on the reference: `sign_out(conn, secret: &f/1)` raises `CaseClauseError` in `Guardian.Token.Jwt.decode_token/3`, because JOSE returns `{:error, :function_clause}` for the unresolved function. `sign_out(conn, secret: f.(conn))` works. The docs therefore say a function "raises while the token is verified" rather than "inside JOSE".
- `:refresh_from_cookie` does not inherit `:secret`. This is the upstream decision, kept and tested.
- Call count: the spec requires exactly once per verify-plug call (upstream test) and no call without a token or cookie. Issuing call counts are unspecified. Mutant M3 (SlidingCookie resolving twice) passes the hidden tests.

## Bundle layout decisions (worth a reviewer look)

1. **`allowed_edit_prefixes` = `lib/`, `test/`, `guides/`, `CHANGELOG.md`, `mix.exs`.** The exact upstream replay touches `mix.exs` (guide registration). `Eab.Candidates` validates `reference.patch` against the allowed prefixes, and `upstream-docs.patch` may only hold `.md`/`.txt`, so `mix.exs` has to be in `reference.patch` and allowed. `guides/` and `CHANGELOG.md` are allowed so that a solver who documents the feature is not rejected. The integrity risk of allowing `mix.exs` is low: required hidden tests must still run and pass.
2. **`upstream-docs.patch` contains all Markdown changes from baseline to reference**, the upstream ones and the curator's. The curator edits modify the upstream-created guide. Reconstruction applies `reference.patch`, then the tests, then docs, so a separate curator docs patch cannot follow the docs patch. The two-commit history on the reference branch keeps the split auditable.
3. **The curator's extension tests are not on the reference branch.** With `upstream-tests.patch` present, `Eab.Provenance` reconstructs the fixed tree from it, so the branch tests must equal upstream's. The curator tests (9 tests in `plug_test.exs` and `sliding_cookie_test.exs`) live only in `reference-tests.patch` (upstream tests plus curator tests). This departs from "an extension commit carries its own tests", and is forced by the verifier.
4. **Neutral preparation commit** `c251a21`: `test/support/line_buffered_io.exs` and `test/test_helper.exs` (`ExUnit.start(max_cases: 2)`). It is needed because a diagnostic mutant run without it reproduced the Ash 3031 reporter fault: `.EAB_FAILURE_PHASE:` was prefixed by a CLI progress dot, which drops the failure phase. `valid_controls?` requires `starting_failures` to equal the behavioural failures *exactly*, so one lost phase invalidates qualification. The adapter body is byte-identical to the Ash fork's `test/support/line_buffered_io.exs` minus its SPDX header, plus a module rename and `# credo:disable-for-this-file Credo.Check.Refactor.Nesting`. Guardian CI runs credo, which flagged nesting depth. File sha256 `3bcc3b61…e82`. No `environment.patch`. `.tool-versions` already matches the image, so it is unchanged.

## Runtime

- Image `hexpm/elixir:1.18.4-erlang-27.3.4-ubuntu-noble-20260509.1@sha256:11ee3fe5aed7b729f2783b8ae001371a92f5cfe025e84a97b4af06342264493c`. `.tool-versions` at the parent is `erlang 27.3.4` / `elixir 1.18.4-otp-27`, and CI has an Elixir 1.18 / OTP 27 job.
- Dependencies come from `mix.lock`: jose 1.11.12, plug 1.19.2, credo, excoveralls, jason and transitive. With `--only test` there are no native builds and no services.
- The base image lacks CA certificates. Only the fetch container mounted the host `/etc/ssl/certs` read-only. The benchmark's own Dockerfile installs `ca-certificates`.
- `mix deps.get` printed Hex security advisories for plug 1.19.2 and plug_crypto 2.1.1. These are the historical lockfile pins. They are not relevant offline, but they are recorded.

## Hidden acceptance tests: assertion mapping

The files are `test/benchmark/connection_secret_verify_test.exs` (V) and `test/benchmark/connection_secret_issue_test.exs` (I). They use real `Guardian.Token.Jwt` HS512 tokens, three distinct secrets (application, tenant A, tenant B) and the Plug.Test conn, session and cookie helpers. There are no timing assertions. The compiled `TenantPipeline` is defined inside the first verify test's body (revision 2), so a solution that breaks compiled pipelines fails that one named test instead of aborting the file load. Expiry margins are hours (`ttl {1, :hour}`, sliding window `{2, :hours}`), so wall-clock drift cannot flip outcomes. A missing `resolve_secret/2` is reported by an `assert function_exported?` assertion. It is then called through `apply/3`, so baseline compiles without undefined-function warnings.

| Test | Spec basis | Baseline | Incomplete |
| --- | --- | --- | --- |
| V header session and cookie verification use a secret chosen from the connection | Where it applies (verify), compiled pipeline, VerifyCookie signs the exchanged token | fail | pass |
| V a nil secret from the connection fails closed on every verify plug | Fail-closed table; wrong secret is `:invalid_token` | fail | pass |
| V explicit nil secrets fail closed through the token API | Fail-closed table (Guardian API, `Jwt.decode_token/3`) | fail | pass |
| V verify plugs resolve … only when a token is present and once per call | Resolution timing | fail | pass |
| V refresh from cookie takes its own secret option | `:refresh_from_cookie` keeps its own options | fail | pass |
| V static and module function secrets and an omitted secret keep working | Compatibility | pass | pass |
| V resolve_secret is public and resolves only one-argument functions | `resolve_secret` paragraph; exceptions propagate | fail | pass |
| V a verify plug secret function of the wrong arity raises ArgumentError | `:secret` option: other arity | fail | pass |
| I sign_in signs the token with the secret chosen from the connection | Issuing; examples | fail | **fail** |
| I remember_me sets a refresh cookie signed with the connection secret | Issuing | fail | **fail** |
| I remember_me_from_token verifies and reissues with the connection secret | Issuing (verify and sign); wrong secret rejected | fail | **fail** |
| I issuing with a connection secret that resolves to nil issues nothing | Fail-closed table (issuing); `{m, f, a}` resolving to nil | fail | **fail** |
| I sliding cookie verifies and replaces the cookie with the connection secret | Issuing (SlidingCookie) | fail | **fail** |
| I sliding cookie never falls back to the application secret | Fail-closed table (SlidingCookie); no call without a cookie | pass | pass |
| I a secret function of the wrong arity raises ArgumentError when issuing | `:secret` option: other arity | fail | **fail** |
| I issuing without a secret or with static and module function secrets is unchanged | Compatibility | pass | pass |

Discrimination design:
- Every "signed with the connection secret" assertion checks that the token verifies with the tenant secret **and does not** verify with `:secret_key`, so a solution that signs with the global key cannot pass.
- The nil cases use tokens signed with the **application** key. A solution that falls back to `:secret_key` would then accept or re-issue them, and the tests catch that.
- Positive compatibility checks prevent passing by disabling static, `{m, f, a}` or omitted secrets.

Requirement groups in `case.json` (5) map every one of the 16 required checks: verify, issue, fail-closed, interface and compatibility. `TaskContract.validate!/1` accepts the contract.

Diagnostic mutants (not controls) were run against the hidden tests on the reference:
- M1: `resolve_secret` drops `nil`, so the call falls back. It fails 4 tests: V nil-verify, V resolve_secret, I nil-issuing and I sliding-never-falls-back.
- M2: SlidingCookie strips `:secret` before re-signing. It fails I sliding-replace and I compat.
- M3: SlidingCookie lets `remember_me` re-resolve (an acceptable alternative). It passes all 16.
- M4 (revision 2): `VerifyHeader.init/1` wraps the function in an anonymous fn, which cannot be escaped into a compiled pipeline. Only "header session and cookie verification use a secret chosen from the connection" fails, in the test phase with `ArgumentError: cannot escape`. The run completes all 16 tests.

## Preservation

`mix test test/guardian_test.exs test/guardian/plug_test.exs test/guardian/plug/verify_header_test.exs test/guardian/plug/verify_session_test.exs test/guardian/plug/verify_cookie_test.exs test/guardian/plug/sliding_cookie_test.exs test/guardian/token/jwt_test.exs`

There are 155 tests: the plug entry points, the verify plugs, SlidingCookie, the JWT token module and the core API. They pass on the baseline and on the reference (regression phase). Files are listed explicitly, not as directories, so that the grader's `extra -- args` de-duplication of changed test files is exact.

## Verification log (2026-10-26)

Every container used the pinned image with `--cpus=2 --memory=6g --user 1000:1000 --rm`, one at a time. Dependencies were fetched once, with network, by `mix deps.get --only test`. Every test run used `--network none`, `MIX_ENV=test ERL_FLAGS='+S 2:2' TZ=UTC`, through the grader's command form `elixir -r formatter.exs -S mix test … --seed 0 --formatter ExUnit.CLIFormatter --formatter ElixirAgentBenchmark.TrustedFormatter`, with `priv/fixtures/grade_formatter.exs` copied. The scripts are in the session scratchpad (`guardian-748/scripts/{run,mkws,grade,control}.sh`, `decode.py`, `check_controls.py`, `contract_check.exs`), and logs are in `guardian-748/logs/`. No durations were recorded or interpreted.

Full suites:

| Tree | Result |
| --- | --- |
| Upstream parent `4073c73`, before preparation | 245 tests, 0 failures |
| Prepared baseline `c251a21` | 245 tests, 0 failures, rc 0 |
| Reference branch `830ac06` (upstream tests) | 284 tests, 0 failures, rc 0 |
| Reference tree + curated `reference-tests.patch` | 293 tests, 0 failures, rc 0 |

`mix format --check-formatted` and `mix credo` pass on the baseline and the reference.

Grader-flow controls (`control.sh`) repeat `Grader.do_grade`. They apply the patch, then run submission (preservation plus changed tests), restore `test/`, apply the acceptance overlay, run hidden, restore, then run regression:

| Control | Submission | Hidden (16) | Regression |
| --- | --- | --- | --- |
| Unchanged | 155/155 pass | 3 pass, 13 fail, all phase `test`; set equals `starting_failures` exactly | 155/155 pass |
| Reference + reference-tests | 203/203 pass | 16/16 pass | 155/155 pass |
| Incomplete (upstream `lib/` only) | 155/155 pass | 10 pass, 6 fail (issuing), all phase `test`, all in `starting_failures` | 155/155 pass |
| Reference + reference-tests + integrity | no tests (compile-time `System.halt(0)`), not completed | not completed | not completed |

- Coverage probe: `reference-tests.patch` only, on the baseline, running the 6 changed files. It completed with 180 tests and rc 2, and 33 tests failed in the test phase. Every one of them passed in the reference submission.
- `check_controls.py` replays `valid_controls?` on these outcomes, and every condition holds.
- Source reconstruction: baseline export, then `git apply --index` of `reference.patch`, `upstream-tests.patch` and `upstream-docs.patch`, gives tree `1ee0cdc8…`, which equals the reference branch tree. This was first verified on the pre-preparation pair (`78aaa473…` to `4e2bc549…`). The patches are byte-identical after the rebase.
- `contract_check.exs` loads the project's own `task_contract.ex`, `grader.ex` and `provenance.ex` in the pinned image. `TaskContract.read/1` and `Provenance.validate!/2` succeed. `validate_patch` returns `{:ok, []}` for the three test patches against `test/`, and for `reference.patch`, `incomplete.patch` and `integrity.patch` against `allowed_edit_prefixes`.
- Reporter check: the M2 mutant without preparation produced 1 dot-prefixed `EAB_FAILURE_PHASE` line. With preparation, there were 0 in 3 reruns.

`integrity.patch` is a byte copy of `.local/fork-migration/drafts/operately-pr-1069/integrity.patch` (sha256 `9345cf52…d193`).

## Revision 2 (2026-10-26)

Changes requested by the coordinator after the independent review approved revision 1:

1. **One error shape.** `ticket.md:53` now names `{:unauthenticated, {:error, :secret_not_found}}` only, and `ticket.md:82` (example) matches. The hidden check (old `acceptance.patch:94-97` and `:168`) now asserts `reason == {:error, :secret_not_found}`, and the two-shape helper is removed.
2. **`TenantPipeline` built in the test body.** The module was moved from file level (old `acceptance.patch:309-317`) into the first verify test (new `:365-373`). Diagnostic M4 confirms that the failure stays named.
3. **Curator docs corrected on the reference branch** (amend: `830ac06` becomes `297172d`). The CHANGELOG and guide now state the exact handler reason and add the `sign_out` fixed-secret note. `upstream-docs.patch` is regenerated, and reconstruction gives `ac9a7cd2…`, equal to the reference tree. `provenance.json` lines 5, 7 and 24 are updated to the new commit and tree.
4. **Non-goal reworded** (`ticket.md:96`): the function form in `sign_out/3` is out of scope, and revocation with static, `{m, f, a}` or `nil` secrets behaves as the Guardian API row (`ticket.md:55`) says.
5. **Standard compile clarification** (`case.json:139`): `clarifications.environment` gains the sentence used by every feature case: "Added or changed test files are also compiled and run against the starting source, so each of them must compile there." `TaskContract.read/1`, `Provenance.validate!/2` and the patch-path checks still pass.

Unchanged byte for byte: `reference.patch`, `reference-tests.patch`, `upstream-tests.patch`, `incomplete.patch` and `integrity.patch`. The requirement texts never named the reason shape, so the grading contract in `case.json` is unchanged apart from the clarification sentence.

Revision 2 verification (same bounds: pinned image, `--cpus=2 --memory=6g`, `--network none`, one container at a time, trusted formatter, seed 0, no timing). The revision 1 logs are kept in `guardian-748/logs/v1/`.

| Run | Result |
| --- | --- |
| Unchanged (grader flow) | submission 155/155; hidden 3 pass, 13 fail, all phase `test`, set equal to `starting_failures`; regression 155/155 |
| Reference + reference-tests (grader flow) | submission 203/203; hidden 16/16; regression 155/155 |
| Incomplete (grader flow) | submission 155/155; hidden 10 pass, 6 issuing tests fail, all phase `test`, all in `starting_failures`; regression 155/155 |
| Reference + integrity | not completed in any phase (compile-time halt) |
| Full suite, reference branch `297172d` | 284 tests, 0 failures, rc 0 |
| Full suite, reference tree + curated tests | 293 tests, 0 failures, rc 0 |

`check_controls.py` reports every `valid_controls?` condition satisfied. The coverage probe log is reused from revision 1, because `reference-tests.patch` and the baseline are unchanged. The `mix format --check-formatted` run on the hidden test files passes.

## Bundle hashes (sha256)

Revision 2:

```
cdfe9755fd95757fb815fb103cd18229d004549ecd5b8e289be57774f2783e6b  acceptance.patch
e04e706d3661a42e83eaf46a53daa1cf59e8a55921bf54f55eeff547d2540163  case.json
9554fe5edf41ed6340ea1de3e169b522697bf900a2456703f0aa9ec8edef3c24  incomplete.patch
9345cf52f8dccb1cf508da8776f27ce7317661503c16dd2710d053c7416dd193  integrity.patch
38ce2beaef94f38b94dd1af89358028196c7e9624de9e83d3f0901c3489d881d  provenance.json
44d3473aacc5b963de329d4941a854e2cc1aa16c33feede0554c22975012c23c  reference.patch
e93c8add52ec955d9a012e13f208312eed7d92fdb14a7e7686e55b06083b87dd  reference-tests.patch
edc3259cf6bc984fe4f4b69033e72d54314ae8f9726a9c00d63b8ff92f1d5829  ticket.md
fed512626cf0c59ef56130a8c10b2f74978cf319a9b7b8ba42cd986a7c2fa115  upstream-docs.patch
25ba2f9cd4cbbfb9257709c8715d0e5895ca17a5dd15ae1fb16ff725dfd275e2  upstream-tests.patch
```

Revision 1 (superseded) hashes of the changed files: `acceptance.patch` `5f282cf8…2447`, `case.json` `971c517e…a9`, `provenance.json` `cfd02458…7dabb`, `ticket.md` `0d96901d…5c24`, `upstream-docs.patch` `fef8324c…9c02`.

## Remaining gates

1. Push the branches to the fork centrally, open the draft source-pair PR, and fix the `pull_request` number if it is not #1.
2. Import through `Eab.Candidates`, get an independent requirements-first review, and run three fresh qualification rounds.
3. Run two Opus 5.5 xhigh validations (ADR 0012/0013).

## Open questions for the reviewer

- Allowing `mix.exs`, `guides/` and `CHANGELOG.md` edits (forced by the exact replay's `mix.exs` hunk).
- Curator Markdown inside `upstream-docs.patch`, and curator tests kept off the reference branch (both forced by the current provenance verifier).
