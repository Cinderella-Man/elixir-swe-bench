# plausible-pr-5939 — schema-v2 conversion notes (curator only, not part of the bundle)

Author: case-author agent, 2026-10-26. Nothing was run: no Docker, mix, tests or qualification.

## Files changed in the bundle

- `case.json`: schema v2, `task_kind: bug_fix`, `suite` renamed to `project`, legacy contract keys removed, `grading` added, images pinned by digest.
- `incomplete.patch`: new; byte-identical to the legacy partial (`replace`, 1 occurrence).
- `integrity.patch`: new; the legacy halt patch text from `lib/eab/grader.ex`.
- Unchanged: `repository`, `provenance.json`, `reference.patch`, `reference-tests.patch`, `acceptance.patch`, `upstream-tests.patch`, `upstream-docs.patch`, `ticket.md`, clarifications (no host-specific text was present).

## Image pins (2026-10-15 evidence.json, `runtime.base_image`, `node_image`, `service_engines`)

- `hexpm/elixir:1.19.4-erlang-27.3.4.6-alpine-3.22.2@sha256:c129490f…0a1e`
- `node:23.2.0-alpine@sha256:ecefaffd…7c6c`
- `postgres:16-alpine@sha256:721873c3…80ea`
- `clickhouse/clickhouse-server:24.12.2.29-alpine@sha256:e5e232b4…437f`

The recorded `services` values (`sha256:9f51…`, `sha256:5af1…`) are the case's prepared service image IDs, not registry digests, so they were not used.

## Starting failures (empty_patch.hidden, phase `test`)

1. `ChangeDomainTest::… Site guest with role editor can submit the form and it changes the record in the database`
2. `ChangeDomainTest::… Team member with role editor can submit the form and it changes the record in the database`

Both were missing from the legacy `required_acceptance_tests` and were added. `required` = the two legacy `AuditDomainScopeTest` checks + these two (4).

## Assertion mapping

| Requirement | Checks | Why the text says what it says |
| --- | --- | --- |
| `editors-change-domain` | the two editor submissions | The tests mount, submit and reload `domain` and `domain_changed_from`; the text states the previous-domain record, which the ticket leaves implicit. Owner/admin variants run in the same suite but are not `required`. |
| `editor-access-stays-site-scoped` | both `AuditDomainScopeTest` checks | Both assert `Ecto.NoResultsError` on mount and an unchanged domain. The audit asked to disclose the existing denial convention when it is graded, so the text names it. Viewer and unrelated-user denials (`DomainPermissionTest`, not `required`) are mentioned as context. |

## BLOCKER: the incomplete control cannot pass v2 qualification

`Grader.valid_controls?/5` requires the incomplete control to fail at least one declared starting failure. The legacy partial (`:editor` → `:editor, :viewer`) grants the editor access, so on 2026-10-15 both starting failures **passed** under it. Its behavioral failures were:

- `AuditDomainScopeTest::… a guest editor of one site is still a viewer of another site in that team`
- `DomainPermissionTest::… guest viewers cannot mount the domain-change form`
- `DomainPermissionTest::… team viewers cannot mount the domain-change form`

None of these is a starting failure, and none can be one, because they pass on unchanged code. Rules 3, 4 and 6 of the brief therefore cannot all hold. I kept the byte-identical legacy `incomplete.patch` (rule 6), so qualification will report `valid: false` for this case. A curator must decide.

Possible replacement, **not applied and not executed**: a partial that checks the user's *team* role instead of their role on the site. It lets team Editors in but keeps guest Editors out. It should fail only starting failure 1 and keep every denial passing.

```diff
--- a/lib/plausible_web/live/change_domain.ex
+++ b/lib/plausible_web/live/change_domain.ex
@@ mount/3
-    site =
-      Plausible.Sites.get_for_user!(socket.assigns.current_user, domain,
-        roles: [
-          :owner,
-          :admin,
-          :super_admin
-        ]
-      )
+    user = socket.assigns.current_user
+
+    site =
+      Plausible.Sites.get_for_user!(user, domain,
+        roles: [:owner, :admin, :editor, :viewer, :super_admin]
+      )
+
+    unless Plausible.Auth.is_super_admin?(user.id) or
+             match?({:ok, role} when role in [:owner, :admin, :editor],
+               Plausible.Teams.Memberships.team_role(site.team, user)) do
+      raise Ecto.NoResultsError, queryable: Plausible.Site
+    end
```

Expected behavior, traced against baseline `get_for_user_query`, which filters on `coalesce(gm.role, tm.role)`, and `Memberships.team_role/2`. A guest has team role `:guest`.

| Check | Expected result |
| --- | --- |
| Guest editor (starting failure 1) | fails: raises |
| Team editor | passes |
| Guest or team viewer | denied |
| Unrelated user | denied |
| Guest editor viewing another site | denied |
| Editor of another team | denied |

The patch would need a proper `index`/hunk header against the baseline commit `d6673fbb…`, then a qualification round.

## incomplete.patch verification

Computed with a Python mirror of `legacy_partial_patch/1`. The probe from `cases/plausible-pr-5939/case.json` (`replace`, `before: "+          :editor,"`, `occurrences: 1`) split-count = 1, so `str.replace`. `diff reference.patch incomplete.patch` shows exactly one changed line. sha256 `dd962d79b5a4edde87fac10ab9186a08e9026110fd8691f07912d79b8c69e9ce`, 540 bytes.

## Other reviewer notes

- `Candidates.import/1` refuses IDs present in `Inventory.all()`. The legacy `cases/plausible-pr-5939` must leave `cases/` before this draft is imported.

## Curator decision: incomplete control (2026-10-26)

The legacy probe (adding `:editor` together with `:viewer`) passes both starting failures, so it cannot satisfy the v2 rule that the incomplete patch fail at least one starting failure. `incomplete.patch` is now the replacement sketched above, generated as a real diff against baseline `d6673fbb`: it admits users whose *team* role is owner, admin or editor and denies everyone else, so team Editors gain access while guest Editors (team role `:guest`) are still refused. `get_for_user!/3` already preloads `site.team`, and `Plausible.Teams.Memberships.team_role/2` and `Plausible.Auth.is_super_admin?/1` exist at the baseline. It is expected to fail only the guest-editor starting failure; qualification will confirm. SHA-256 `7d92e3e84b4f6128e1091c94fd0fcb785c64f4821f43fc2d2dcd11bf662df65f`.
