# absinthe-pr-1176: curator notes (draft, unadmitted)

These notes are for the curator and reviewer. They stay outside the bundle and are never shown to the solver.

- **Date:** 2026-10-26.
- **Author:** curation subagent (Opus 5.5) acting as case author.
- **Bundle:** `.local/new-cases/drafts/absinthe-pr-1176/`.
- **Status:** draft. It is not imported, not reviewed and not admitted. No model runs were made.

## Source record

- **Source type:** a historical merged upstream PR, plus a curator extension (ADR 0013).
- **Project:** absinthe-graphql/absinthe, licensed MIT (`LICENSE.md`, copyright Bruce Williams and Ben Wilson).
- **Upstream PR:** <https://github.com/absinthe-graphql/absinthe/pull/1176>, "Allow schema declaration directives".
  - 16 commits by Maarten van Vliet.
  - Merged by Ben Wilson as a true merge on 2022-08-09.
  - Merge commit `a2766843d75b97bea922fb1e82d9be87392bfbfe`.
  - First parent `6ecb1470cdfd0d7340782431ef825ab84c82b921` (Absinthe 1.7.0).
- **Upstream trees:** the base tree is `3a654d7f1af07f2f95c52b507f4a8e5fdd59af64` and the merged tree is `3a1431168c57e7714643e64449a5b9739b5cc297`.
- **Follow-up #1186** ("Ensure root objects are marked as referenced correctly") is outside this reference, as the dossier says. No hidden check depends on it.
- **Fork:** `https://github.com/Cinderella-Man/absinthe`. On 2026-10-26, `git ls-remote` without credentials could not read it, so it is absent or private. Nothing was pushed, forked or written to GitHub.
- **Local clone:** a full clone (not partial) is at `.local/new-cases/repos/absinthe`. Both branches exist only there.

### Branches (local only, to be published centrally)

| Branch | Commit | Tree | Contents |
| --- | --- | --- | --- |
| `codex/absinthe-pr-1176-benchmark` | `6ecb1470cdfd0d7340782431ef825ab84c82b921` | `3a654d7f1af07f2f95c52b507f4a8e5fdd59af64` | The upstream PR's first parent, with no preparation commit. |
| `codex/absinthe-pr-1176-reference` | `32feb786256d155ea2052dfc24da272a2d42169e` | `92558f64cc45335cd9ce48da018982534fb53cc6` | The parent is the unchanged upstream merge `a2766843`, which keeps the original authorship and all 16 PR commits. On top is one curator commit, authored by Kamil Skowron and co-authored by Claude, titled "Benchmark curator extension: complete schema declaration extensions". |

- **No preparation commit was needed.** The base already compiles, and its full suite passes offline in the pinned image with the trusted formatter. ExUnit output parses as completed.
- **Reconstruction was verified locally.** The base tree, plus `reference.patch`, `upstream-tests.patch` and `upstream-docs.patch` applied with `git apply --index`, gives exactly `92558f64…`.
- **The source-pair PR number is provisional.** `provenance.json` uses `pull_request` `…/absinthe/pull/1`, with a `pull_request_note` that marks it as provisional. Confirm or correct it when the draft PR is created centrally.

To publish centrally, using the create-only check from `docs/prepared-fork-sources.md`:

```
git -C .local/new-cases/repos/absinthe push <fork> \
  --force-with-lease=refs/heads/codex/absinthe-pr-1176-benchmark: \
  --force-with-lease=refs/heads/codex/absinthe-pr-1176-reference: \
  codex/absinthe-pr-1176-benchmark codex/absinthe-pr-1176-reference
```

## Curator extension (reference branch commit `32feb786`)

The extension consists of three implementation-only changes in 4 files and changes no tests on the branch. The reference branch's full suite stays green.

1. **SDL extension operation types become roots.**
   - Files: `apply_declaration.ex`, which exposes `mark_roots/2` and reuses it, and `apply_type_extensions.ex`, which re-marks roots after it extends the declaration.
   - Upstream gap: with `extend schema { mutation: Writes }`, upstream renders `mutation: Writes` in the declaration, yet introspection reports `mutationType: null` and mutations return "Operation "mutation" not supported". The upstream test only inspected the declaration struct.
   - Why: this makes extensions mean what the GraphQL specification says they mean.
2. **The reserved-identifier check stays for top-level `object :query`, `:mutation` and `:subscription`.**
   - File: `notation.ex`. Inside `extend`, the identifiers are allowed.
   - Upstream gap: upstream removed the check entirely, because `extend object(:query)` needs those identifiers. The commit message said the case was "also covered by validation phases". A probe showed that a lone top-level `object :query` then compiled and silently became a query root named `Query`.
   - Why: keeping the check preserves the baseline contract and its existing test "cannot use reserved identifiers".
3. **SDL declaration entries get `__reference__`.**
   - File: `sdl.ex`.
   - Upstream gap: an SDL declaration or extension entry that names an undefined type crashed upstream with `UndefinedFunctionError nil.location/0` while the error was being built. The baseline accepted it silently.
   - Why: it now raises `Absinthe.Schema.Error` "In field Mutation, "Missing" is not defined in your schema", matching the macro path.

As a diagnostic, the acceptance file was run against upstream-only `a2766843`. It fails exactly the four tests that exercise the extension:

- both SDL extension tests (mutationType is nil);
- the root-objects test (a top-level `object :query` compiles);
- the invalid-declaration test (`UndefinedFunctionError`).

The other 7 pass.

## Implementation scope

The reference has **15 implementation files**: upstream's 14 plus `notation/sdl.ex`.

| Group | Files |
| --- | --- |
| Blueprint building and walking | `blueprint/schema.ex`, `blueprint/transform.ex` |
| Phases | `apply_declaration.ex` (inferred declaration, root marking), `apply_type_extensions.ex` (extends the declaration and re-marks roots), `pipeline.ex` (ApplyDeclaration before ApplyTypeExtensions), `validation/type_references_exist.ex` |
| Compile and providers | `compile.ex`, `populate_persistent_term.ex`, `schema.ex`, `schema/compiled.ex`, `schema/persistent_term.ex` |
| Notation | `notation.ex` (the `schema` and `extend schema` macros, placement, the reserved check), `notation/sdl.ex` (references), `notation/sdl_render.ex` (renders the real declaration) |
| Introspection | `type/built_ins/introspection.ex` (description from the declaration) |

- **Tests** are counted separately: upstream changed 7 test files. Documentation is one `CHANGELOG.md` line.
- **Cross-component consistency.** The macro and SDL notations, the declaration phases, both schema providers, introspection and SDL rendering must all agree on one declaration: its description, directives and roots.

## Feature spec (`ticket.md`)

- **Headings:**
  - Goal
  - Public interface
  - Decided behaviour, with subsections for writing a declaration in a macro schema, the inferred declaration, the schema description, extending the declaration and extending root objects
  - Errors
  - Scope and non-goals
  - Compatibility
- **Public interface, macros:**
  - `schema do … end`, containing `description`, `directive` and `field :query|:mutation|:subscription, <root id>`;
  - `extend schema do … end`;
  - `extend object(:query|:mutation|:subscription)`.
- **Public interface, SDL:** a described `schema @dir { … }`, `extend schema @dir { … }`, and the directive-only form `extend schema @dir`.
- **Observation points:** `Absinthe.Schema.to_sdl/1`, `__schema { description queryType mutationType subscriptionType }` and execution. No new public function is required, and the PersistentTerm provider must behave the same.
- **Behaviour changes relative to the baseline (five):**
  1. `__schema { description }` no longer returns the "Represents a schema" placeholder. It returns the declared description or `null`. This is in the spec and checked.
  2. `to_sdl` no longer prints the placeholder above `schema`, and the spec says existing tests that expect it need updating. This is in the spec and checked, including the exact `to_sdl` of a plain schema.
  3. The order of entries in the rendered `schema` block can differ from the baseline. The spec says it is unspecified, and no check depends on it, since entries are compared as sets.
  4. Directives on SDL schema declarations are now validated against the schema location. This is in the spec and checked.
  5. The `field` misplacement error message now also lists the `schema_declaration` scope ("… within `input_object`, `interface`, `object`, `schema_declaration`. …"). The spec does not mention it and no hidden check covers it. The baseline test `notation_test.exs` "field cannot be toplevel" expects the old text, so that file is not in preservation.
- **Decided non-goals:**
  - duplicate operation entries;
  - declarations without `query`;
  - extension descriptions;
  - applied directives in introspection;
  - no change to how macro schemas choose their roots (a defined but unlisted root still executes and is omitted from the rendered block; test 1 now checks this);
  - a macro declaration entry naming a non-root object, such as `field :mutation, :thing`, is undecided and unchecked.
- **What the spec excludes:** file names, phases, struct fields, reference code and PR numbers. The Apollo Federation 2 motivation is mentioned without a link.

## Checks

The acceptance file is `test/benchmark/schema_declaration_test.exs`, module `Absinthe.Benchmark.SchemaDeclarationTest`, `async: false`.

- **Isolation.** Each test compiles its own uniquely named prototype and schema modules with `Code.compile_string` inside the test body. A compile failure becomes a `flunk`, an `ExUnit.AssertionError`. An expected error is compared by exception module.
- **Starting failures.** On the baseline, all 11 tests fail in the test phase with `ExUnit.AssertionError`, so all 11 are `starting_failures`.

| Requirement id | Checks (`::test …`) |
| --- | --- |
| macro-declaration | the schema macro declares the description, directives and query root; persistent term schemas expose declarations like compiled schemas |
| schema-extensions | macro schema extensions add directives to the inferred declaration; macro schema extensions merge directives and operation entries into a declaration; SDL schema extensions add directives and operation types to a declaration; SDL schema extensions apply to the inferred declaration |
| schema-description | SDL schema declarations report their description and directives; schemas without a declared description report and render none |
| root-objects | root objects can be extended but not defined with object |
| compile-errors | misplaced or repeated schema declarations fail at compile time; invalid directives and undefined types in declarations fail at compile time |

Choices that keep the checks from overconstraining a valid solution:

- Rendered entries are compared as sets.
- Two-directive headers accept either order.
- The description is checked as the line immediately above `schema`, `"text"`, matching how type descriptions render.
- Queries use roots named `Query` or `RootQueryType`. Introspection fields are attached only to roots with those names, which is a pre-existing limitation.
- No check executes a mutation while the schema has an SDL subscription root. That combination crashes in `Telemetry.on_complete/2` on the baseline as well, another pre-existing limitation.

Where each obligation is visible to the solver:

- `ticket.md`.
- The existing test that shows the reserved-identifier message: `test/absinthe/schema/notation_test.exs`, "cannot use reserved identifiers".
- The existing extension error for undefined types.
- The existing directive rendering on types.

### Preservation (`grading.preservation`)

- **Size:** 41 paths and 554 tests.
- **Coverage:** schema rules, notation and experimental extension tests, introspection integration, root operation execution, phases, pipeline, types, blueprint and the `mix absinthe.schema.sdl/json` tasks.
- **Behaviour:** every selected test passes on both the baseline and the reference implementation.
- **Excluded files, which change or are unstable:**
  - `full_test.exs`, `sdl_render_test.exs`, `type_system_directive_test.exs` and `schema_test.exs` expect the placeholder description;
  - `notation_test.exs` expects the `field` placement message, which now lists `schema_declaration`;
  - `import_directives_test.exs` has a test tagged `@tag :skip`;
  - `subscription_test.exs` is timing-sensitive, with `assert_receive` broadcasts.
- **Pending-tagged tests:** `permitted_exclusion_tags: ["pending"]` is set because the project's test helper excludes `pending`. This only matters if a solver edits one of those files.

### Controls

- **`reference-tests.patch`.** These are the upstream hunks for three files: `full_test.exs`, `notation_test.exs` and `sdl_render_test.exs`. All three compile on the baseline. Upstream's other test files define schemas at module level with the new macros, so they cannot compile on the baseline. After review R4, the upstream hunk that deletes `notation_test.exs` "object cannot use reserved identifiers" is dropped, because the reference keeps that rule; the test passes on both the baseline and the reference. All other hunks are byte-identical to upstream apart from line offsets. The exact upstream test diff stays in `upstream-tests.patch`.
- **`incomplete.patch`.** This is the reference minus `apply_type_extensions.ex`, `type_references_exist.ex` and `pipeline.ex`. It represents a plausible solver who supports declarations, descriptions and rendering but never applies `extend schema`.
- **`integrity.patch`.** This is a byte-for-byte copy of `.local/fork-migration/drafts/operately-pr-1069/integrity.patch`, which writes `lib/eab_halt.ex` containing `System.halt(0)`.

## Verification (Docker, functional only; no timing recorded or interpreted)

- **Image:** `hexpm/elixir:1.13.4-erlang-24.3.4.17-ubuntu-jammy-20250126@sha256:2a8f5a70…6d`. The tag was re-resolved to this digest with `docker buildx imagetools inspect`.
- **Resources:** `--cpus=2 --memory=6g`, uid 1000, one container at a time, every container `--rm`. None were left behind.
- **Dependencies:** fetched once with network, using `mix local.hex 2.5.3 --force && mix local.rebar --force && mix deps.get --only test`. On Elixir 1.13.4 this installed Hex 2.6.0, which is worth noting for the controller recipe. Everything else, including compilation and every test, ran with `--network none`.
- **Command shape:** `elixir -r formatter.exs -S mix test … --seed 0 --formatter ExUnit.CLIFormatter --formatter ElixirAgentBenchmark.TrustedFormatter`, using `priv/fixtures/grade_formatter.exs`.
- **Grader simulation.** The runner is `.local/new-cases/work/absinthe-pr-1176/bin/grade.sh`. It follows `Grader.do_grade` step by step: patch, then the submission run with changed tests, then restoring `test/`, the hidden run, restoring, the regression run, and the coverage probe on a fresh baseline. The image has no git, so the git steps run on the host between container runs.
- **Validity check.** The raw outputs were then fed to the benchmark's real `Grader.parse/2`, `behavioral_failures/1`, `control_tests/2` and `valid_controls?/5`, with `TaskContract.read/1`, `Grader.validate_patch/2` and `Provenance.validate!/2` loaded from `lib/eab`. That script is `.local/new-cases/work/absinthe-pr-1176/bin/validate_bundle.exs`, and its output is `logs/validate.out`. `valid_controls?` = **true**.
- **What was not run:** `Eab.Candidates.import/qualify`. The controller was busy and is off limits.

| Control | Submission (preservation + changed tests) | Hidden acceptance (11) | Regression (554) | Coverage probe on baseline | Overall |
| --- | --- | --- | --- | --- | --- |
| Baseline (empty patch) | pass, 554 | completed; 11 failed in the test body, all `AssertionError` | pass | n/a | rejected (correct) |
| Reference (reference + reference-tests) | pass, 620 | 11/11 pass (also seeds 1, 4242, 987654 before review) | pass | completed (66 tests); 4 behavioural failures (3 in `notation_test`, including the placement message, and 1 in `sdl_render`) | **accepted** |
| Reference + integrity | not completed (halt) | not completed | not completed | n/a | rejected; `bypass_executed` true |
| Incomplete | pass, 554 | completed; 5 failed in the test body (macro inferred, macro merge, SDL declared extension, SDL inferred extension, invalid directives/undefined types), 6 pass | pass | n/a (coverage off) | rejected; failures ⊂ starting |
| Diagnostic: upstream-only `a2766843` | — | 7 pass, 4 fail (the curator-extension checks) | — | — | — |

Full suites, run offline with the trusted formatter at seed 0:

| Tree | Tests | Passed | Failed | Excluded (`pending`) | Skipped |
| --- | --- | --- | --- | --- | --- |
| Baseline `6ecb1470` | 1329 | 1325 | 0 | 3 | 1 |
| Upstream merge `a2766843` | 1336 | 1332 | 0 | 3 | 1 |
| Reference branch `32feb786` | 1336 | 1332 | 0 | 3 | 1 |
| Reference implementation with the baseline's tests | 1329 | 1324 | 5 | 3 | 1 |

After review, the reference-branch full suite was rerun from the unchanged branch tree, with the same result: 1336 tests, 0 failures (`logs/suite/reference-full-r2.*`).

The 5 failures in the last row correspond to behaviour changes 1, 2 and 5 above:

- four tests expect the placeholder description: full_test, sdl_render, type_system_directive and schema_test `to_sdl`;
- one expects the old `field` placement message. This change is unchecked and not in the spec.

With upstream alone, a sixth test also failed, "cannot use reserved identifiers". Curator change 2 restores it.

Logs are in `.local/new-cases/work/absinthe-pr-1176/logs/`: `suite/`, `empty/`, `reference/`, `integrity/`, `incomplete/`, `iter/`, and `probe*.log`. The control rows above come from the post-review rerun; the pre-review control logs are in `logs/round1-v1/`, and the pre-review bundle files are in `logs/*-v1.*`. They contain ExUnit's routine "Finished in" lines, which are not evidence of anything.

## Pre-existing limitations found (unchanged; tests avoid them)

- Introspection fields (`__schema`, `__type`) are attached only to query roots named `Query` or `RootQueryType`.
- Consider an SDL type that a declaration names as a root under a different name, such as `schema { mutation: Writes }`. Combining it with `extend type Writes` fails `TypeReferencesExist` ("target type :writes is not defined") on the baseline, upstream and the reference alike.
- An SDL schema with a subscription root crashes on mutation execution with `FunctionClauseError` in `Absinthe.Middleware.Telemetry.on_complete/2`.
- A macro `schema` block with no entries renders `to_sdl` as an `Inspect.Error` string, both upstream and on the reference. The spec makes this a non-goal: a declaration should list `query`.

## Reuse from the 2026-10-23 session (`.local/absinthe-1176/`, left untouched)

**Reused after verification:**

- The image choice and its digest, which I re-resolved.
- The upstream diff split. `reference.patch` without the extension, `upstream-tests.patch` and `upstream-docs.patch` are byte-identical to fresh `git diff --abbrev=7` output, apart from index-line abbreviation. The old `reference-tests.patch` was too, until review R4 dropped one hunk.
- The choice of compile-safe reference tests.
- The "no extension application" design for the incomplete control.
- The `Code.compile_string`-in-test-body approach and the SDL declaration parser helper.
- The old base-suite result, which I reproduced (1329, with the same exclusions).

**Changed:**

- The case now has a fork and branch layout, with no prep commit.
- The curator extension is new. The old reference was upstream-only, and the old draft test codified the SDL-extension inconsistency by checking rendering only.
- The spec was rewritten under ADR 0013.
- The acceptance tests were rewritten: 11 tests instead of 8, with compile failures turned into named assertions, PersistentTerm and error coverage, and tolerance for directive and entry order.
- Preservation grew from 496 tests to 554 (adding the pipeline, strict schema, root execution and mix SDL/JSON tasks). The old list also carried no `permitted_exclusion_tags`.
- The incomplete control was rebased onto the new reference.
- `integrity.patch` is now copied from operately-pr-1069.
- `case.json` and `provenance.json` are new, in v2 and fork format.

## Open questions for the reviewer

1. **The three curator changes.** Are SDL extension roots, keeping the reserved-object check and the SDL error references acceptable as an extension under ADR 0013? Change 2 preserves an existing contract rather than adding capability. It could be dropped by also removing the check from the spec and from the root-objects test.
2. **"The reference must pass the project's full existing suite."** I read this as the suite on the reference branch, which is green. Upstream deliberately changed 5 baseline expectations, so the reference implementation cannot pass the baseline's unchanged tests. Four of them (the placeholder) are disclosed in the spec. The fifth, the `field` placement message, is recorded only in these notes and is unchecked. Preservation excludes all of those files.
3. **Macro roots stay macro-defined.** A declared subset only affects rendering, which is upstream behaviour and is stated in the spec. Resolved by review R2: test 1 now checks that an unlisted `mutation` root still executes.
4. **The preservation command.** At 41 paths it is long, and it is shown to the solver as "Test command". A shorter subset is possible if prompt length matters.
5. **Error types.** The spec fixes `Absinthe.Schema.Error` for a repeated macro `schema` block, where a notation-time error would also be defensible. The spec states it, but a reviewer may prefer to accept either.
6. **The fork PR number** in `provenance.json` is provisional (`/pull/1`).

## Review amendments (2026-10-26, independent reviewer R1–R6)

| Id | File | Change |
| --- | --- | --- |
| R1 | `case.json` | The `clarifications.environment` ends with "Added or changed test files are also compiled and run against the starting source, so each of them must compile there." |
| R2 | `acceptance.patch` (test 1) | The schema gains an unlisted `mutation do field :touch … end`. The test expects `mutationType` `RootMutationType`, runs `mutation { touch }`, and keeps the entries as `["query: RootQueryType"]`. |
| R3 | `acceptance.patch` (plain-schema test) | Adds `assert Absinthe.Schema.to_sdl(plain) == "schema {\n  query: RootQueryType\n}\n\ntype RootQueryType {\n  ping: String\n}\n"`. |
| R4 | `reference-tests.patch` | Drops the upstream hunk that deleted "object cannot use reserved identifiers". The other hunks are unchanged except their line offsets. |
| R5 | `ticket.md` (non-goals) | Adds: "In a macro declaration, an entry that names an object which is not a root, such as `field :mutation, :thing`, is undecided. No check covers it." |
| R6 | these notes | Preservation has 41 paths. The five behaviour changes are listed, including the unchecked `field` message change. |

Test names, `required`, `starting_failures` and the requirement mapping did not change. The reference branch, `reference.patch`, `incomplete.patch`, `integrity.patch`, `upstream-*.patch` and `provenance.json` did not change.

Rerun after the amendments, with the same bounds and no timing:

- **Baseline:** hidden completed with 11/11 test-body failures, which still equal `starting_failures`; submission and regression pass (554 tests).
- **Reference + reference-tests:** submission passes with 620 tests (one more, the retained reserved-identifier test, which passes); hidden 11/11; regression passes. The coverage probe completed with 66 tests and the same 4 behavioural failures; the reserved-identifier test passes on the baseline too.
- **Integrity:** submission, hidden and regression do not complete; rejected.
- **Incomplete:** hidden completed, with the same 5 test-body failures, all among the starting failures; submission and regression pass.
- **Reference branch full suite:** 1336 tests, 0 failures.
- **Diagnostic, upstream only:** still 7 pass and 4 fail.
- **Benchmark validity check:** `valid_controls?` = true, and the starting failures equal the empty control's failures (`logs/validate-r2.out`). `mix format --check-formatted` passes on the acceptance test file.

## Next actions

1. Create the fork and push both branches create-only.
2. Open the draft source-pair PR and correct `provenance.pull_request`.
3. Import with `Eab.Candidates.import/1`.
4. Get an independent requirements-first review.
5. Run three fresh qualification rounds.
6. Run two Opus 5.5 xhigh validations through Claude Code.
