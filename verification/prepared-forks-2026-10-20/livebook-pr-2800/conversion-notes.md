# livebook-pr-2800 — v2 conversion notes (curator only, not solver input)

## Conversion

- `case.json`: added `schema_version: 2`, `task_kind: bug_fix` and `grading`, and removed the five legacy fields. Kept `project`, `repository`, `runtime`, `permitted_exclusion_tags`, `test_timeout`, `allowed_edit_prefixes`, `clarifications` and `source_inspiration` as the migration utility wrote them.
- `grading.acceptance` and `grading.preservation` are the old acceptance and regression commands, unchanged.
- Clarifications had no host, speed or shared-machine text, so they are unchanged. The `verification` entry overlaps the v2 test instruction but does not contradict it.
- New `incomplete.patch` and `integrity.patch` files. Provenance and all other patches are byte-identical to the utility's draft.

## starting_failures (7) and required (8)

- Source: `verification/frozen-cases-2026-10-15/qualification-outcomes.json`, `empty_patch.hidden`, keeping failures whose phase is `test`. That stage completed, and all 7 failures are in phase `test`.
- These outcomes apply to this draft:
  - The recorded `identity.case.files` hashes of `reference.patch`, `reference-tests.patch` and `acceptance.patch` equal this draft's files.
  - The fork revision is the same commit: tree `5e7f1028…` matches `provenance.broken_tree`, and `preparation.files` is empty.
- All 7 starting failures were already required. `ordinary runtime errors retain the failing function and argument` passes on the starting source. It stays required as a preservation check.

## incomplete.patch

- Rebuilt from legacy probe `replace` x1: `+      :lists.nth(line, lines)` becomes `+      nil`.
- Computed with Python bytes `split`/`replace`, mirroring `Grader.legacy_partial_patch/1`. The occurrence count is 1.
- Recomputed independently with Perl `s/\Q…\E/…/g`, which is byte-identical. sha256 `a0063893…`. The only diff from `reference.patch` is line 35.
- The recorded `partial_repair` control failed all 7 starting failures in the test body. The probe text recorded in its identity equals the probe used here.

## integrity.patch

- The exact legacy halt text from `grader.ex` `qualify/5`: a new `lib/eab_halt.ex` containing `System.halt(0)`. sha256 `9345cf52…`, identical to the operately draft's.

## Assertion map

| Check (acceptance.patch lines) | Asserted | Requirement |
| --- | --- | --- |
| ErlangDiagnostics, 6 tests (71-91) | type (83), reason (84), offending source (85), `audit.erl:L:C` (86) | erlang-syntax-error-report |
| same | no `ArgumentError` or `retrieving Exception.message` (87-88) | erlang-syntax-error-report |
| same | `metadata.errored`, error code marker on line L (89-90) | erlang-syntax-error-report |
| the 3 multiline tests | line 2, column from line start, offending line only | multiline-error-location |
| ordinary runtime errors (94-102) | bad argument, `list_to_binary/1`, `list_to_binary(1)`, errored | erlang-runtime-errors |
| EvaluatorTest syntax (24-41) | type, description, code (37), `nofile:1:C` (38) | erlang-syntax-error-report |
| EvaluatorTest syntax (43-49) | bad argument, function, call | erlang-runtime-errors |

Some of these behaviors already exist on the starting source, and the requirement text now states them explicitly:
- `process_erlang_error` already classifies TokenMissingError vs SyntaxError and takes the file from the `file:` option (`nofile` by default).
- It already emits a `severity: :error` code marker.
- `errored` comes from `error_result?`.
- The pristine EvaluatorTest already pins the type prefixes.

All message checks are substring-based, so the text says layout and decoration are free (freeze audit: "source line in errors").

## Doubts for the reviewer

- **Stricter than the checks.** The text requires "the offending source line". A message that embedded the whole cell would also satisfy the substring checks. The text follows the reference and the original ticket.
- **Recipe risk.** "the line and column Erlang reports" names a location source, not an implementation. Check that it doesn't read as a recipe.
