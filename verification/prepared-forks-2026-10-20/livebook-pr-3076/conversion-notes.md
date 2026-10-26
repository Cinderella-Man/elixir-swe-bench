# livebook-pr-3076 — v2 conversion notes (curator only, not solver input)

## Conversion

- `case.json` follows the same v2 conversion as 2800. `permitted_exclusion_tags` keeps `git`, since the Git storage tests stay excluded.
- New `incomplete.patch` and `integrity.patch` files. The integrity patch is the exact legacy halt text.

## starting_failures (3) and required (3)

- Source: `qualification-outcomes.json`, `empty_patch.hidden`, failures in phase `test`. The stage completed.
- The 3 `git`-tagged tests are `excluded`, not failed.
- The identity file hashes equal this draft's files. Tree `dfbb0201…` matches `provenance.broken_tree`.
- Added to `required`: `Elixir.LivebookWeb.Hub.EditLiveTest::test personal creates a S3 file system`.
  - This is the curated version of the existing test, submitting only the displayed fields. It fails in the test body on the starting source.

## incomplete.patch

- Rebuilt from legacy probe `replace` x1: `%FileSystem.S3{hub_id: assigns.hub.id}` becomes `%FileSystem.S3{hub_id: nil}`.
- Computed with Python bytes (occurrence count 1) and recomputed with Perl, byte-identical. sha256 `839fff8b…`. The only diff from `reference.patch` is line 10.
- The recorded `partial_repair` control failed 2 of the 3 starting failures in the test body:
  - `failed S3 connectivity…` failed, because with no hub ID the form stays invalid and the button disabled.
  - `personal creates a S3 file system` failed.
  - `missing displayed credentials…` passed.

## Assertion map

| Check | Asserted | Requirement |
| --- | --- | --- |
| EditLiveTest creates S3 (starting test, plus acceptance.patch:5-16) | see list below | save-s3-storage |
| same, `expect_s3_listing` (`Bypass.expect_once`) | exactly one bucket request across change and submit | s3-connection-failure |
| S3Validation missing creds (74-84) | after a change with an empty secret: button disabled, `be blank` shown (82), nothing persisted | s3-form-validation |
| S3Validation failed connectivity (86-103) | see list below | s3-connection-failure |

The create test asserts:
- after a change with only the displayed fields, the button is enabled;
- `{:file_system_created, ^file_system}` matches the struct exactly (personal hub ID, `s3_id(hub, url)`, region `auto`, credentials);
- the view patches back to `/hub/:id` and shows "File storage added successfully";
- the list shows the bucket URL, and the storage is in `Hubs.get_file_systems`.

The failed-connectivity test asserts:
- `expect_once` with a 403 response (91-95);
- the button is enabled after a valid change (98);
- the submit shows "Connection test failed" (100);
- the form remains (101) and nothing is persisted (102).

"can't be blank" and "Connection test failed: " both come from the visible starting source: Ecto `validate_required` and `check_file_system_connectivity/2`.

## Should the expect_once narrowness be stated? Stated, as preserved behavior.

- `Bypass.expect_once` fails a second request to the bucket and also fails if no request arrives. So a repair that also probes during `validate` fails both the create test and the connectivity test, and so does one that never probes on save.
- The starting form already probes only in the `save` handler.
- The visible starting tests already pin this. `creates a S3 file system` and `updates existing S3 file system` both use `expect_once` around a change-then-submit sequence.
- `updates existing S3 file system` passes on the starting source and is part of the preservation suite. So the constraint already binds solvers through visible tests.
- Under v2, a check-enforced detail should still be stated. The clause describes observable network behavior: one request, on save, and none while editing. It does not hint at the hub-ID defect.
- It is cheap to state. The reviewer may drop it as redundant with the visible tests without changing the grading.

## Doubts for the reviewer

- **Ownership and ID wording.** `save-s3-storage` says the saved storage belongs to the personal workspace and has the ID Livebook derives from that workspace and bucket URL. The exact-struct check enforces this, and the original ticket said "saved for that workspace". Confirm it does not read as a recipe for the one-line fix.
- **Exact wording versus substring.** The validation requirement quotes the full "can't be blank", while the check is the substring "be blank".
- **Scope.** Teams and Git storage are not covered. The Teams edits in `upstream-tests.patch` are not run, and the Git tests are excluded via the `git` tag.
