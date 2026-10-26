# plausible-pr-6449 — schema-v2 conversion notes (curator only, not part of the bundle)

Author: case-author agent, 2026-10-26. Nothing was run: no Docker, mix, tests or qualification.

## Files changed in the bundle

- `case.json`: schema v2, `task_kind: bug_fix`, `suite` renamed to `project`, legacy contract keys removed, `grading` added, images pinned by digest.
- `incomplete.patch`: new; byte-identical to the legacy partial (`file_only`, `lib/plausible/site/shared_link.ex`).
- `integrity.patch`: new; the legacy halt patch text.
- Unchanged: `repository`, `provenance.json`, `reference.patch`, `reference-tests.patch`, `acceptance.patch`, `upstream-tests.patch`, `ticket.md`, clarifications (no host-specific text). There is no `upstream-docs.patch` in this bundle.

## Image pins (2026-10-15 evidence.json)

- `hexpm/elixir:1.19.4-erlang-27.3.4.6-alpine-3.22.2@sha256:c129490f…0a1e`
- `node:23.2.0-alpine@sha256:ecefaffd…7c6c`
- `postgres:18-alpine@sha256:77f58511…1873`
- `clickhouse/clickhouse-server:25.11.5.8-alpine@sha256:80ab46b3…9051`

The fixture hashes in evidence.json match the legacy `cases/plausible-pr-6449`, which used these `postgres:18-alpine` and `25.11.5.8-alpine` tags.

## Starting failures (empty_patch.hidden, phase `test`)

1. `AuditSharedLinkEditingTest::test malformed and nonexistent segment selections clear existing associations on edit`
2. `SharedLinkSettings.FormTest::… cannot overwrite the shared link slug via form params`
3. `SharedLinkSettings.FormTest::… does not associate a segment from another site when creating a shared link`
4. `SharedLinkSettings.FormTest::… does not associate a segment from another site when editing a shared link`
5. `SharedLinkSettings.FormTest::… invalid and nonexistent segment selections save without an association`

Failures 2–5 were missing from the legacy `required` and were added. `required` = 11 legacy checks + 4 = 15.

The incomplete control fails starting failures 1 and 4, so `valid_controls?` is satisfied. On 2026-10-15 it also failed three same-site positive checks in hidden tests and "creates a shared link limited to segment" in preservation.

## Assertion mapping

| Requirement | Checks | Why |
| --- | --- | --- |
| `fixed-secret-url` | slug overwrite | Ticket: "Keep the URL fixed when editing". The check also requires the edit to succeed ("Shared link saved"), so the text says the other changes still save. |
| `site-scoped-segments` | starting failures 1, 3, 4, 5 | The ticket states the policy. The text adds what the checks enforce: malformed means non-numeric or negative (`not-an-id`, `-1`), saving clears an existing segment on edit, and the result is the normal "Shared link saved". The ticket's same-site and made-personal preservation is repeated. Those checks (attach on edit, clear on empty, made personal, create limited to segment) run in the graded suite but are not `required`. |
| `settings-access-preserved` | 3 audit denials + 7 `SharedLinkSettingsTest` checks | Existing behavior that the legacy contract already required. The text names the existing `Ecto.NoResultsError` denial, because the audit checks assert it. |

## incomplete.patch verification

The probe is `file_only`, `path: lib/plausible/site/shared_link.ex`. `reference.patch` was split on `"diff --git "` and filtered to the one block starting `a/<path> b/<path>\n`; exactly one matched, and `"diff --git "` was prepended. An independent `awk` extraction of that block is byte-identical. sha256 `7d8a33153cd923b5ec2f847d0e1079f1523e6978e9c3dbdbdba97d8a21f19c98`, 746 bytes.

## Reviewer notes

- Rule 3 adds only the starting failures to `required`. The ticket's positive same-site checks are graded through "all hidden tests pass", but they are not named in `required`, so `required` does not guarantee they are present.
- `Candidates.import/1` refuses IDs that are still in `cases/`.
