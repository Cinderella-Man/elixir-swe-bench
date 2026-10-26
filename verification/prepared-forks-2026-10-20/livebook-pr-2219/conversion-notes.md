# livebook-pr-2219 — curator notes (not solver input)

Schema-v2 conversion of the legacy bundle. Nothing was executed; outcomes cited below come from `verification/frozen-cases-2026-10-15/qualification-outcomes.json` (byte-identical fixtures; all three 2026-10-15 rounds matched it).

## Contract

- `starting_failures` = the empty-patch hidden failures in phase `test` (all `exit`):
  - `FrameContractTest::test nested frame replacement initializes its text input and preserves sibling output`
  - `FrameContractTest::test text inputs appear on replace and append while an edited value survives`
  - `SessionLiveTest::test outputs frame output update with input` (the exact upstream test, added to `required`)
- `required` = the same three checks.

## Assertion mapping

| Check | Asserts | Requirement |
| --- | --- | --- |
| FrameContract nested | Inner frame inside an outer frame is replaced with a text input; label "Nested name", input value "Ada" and sibling terminal output "Sibling output" are rendered | `frame-update-inputs-appear` |
| SessionLive with input | Number input (label, default 1) arrives by `:replace` into an empty frame; label and `input[value="1"]` render after session sync plus one render to drain `send_update` | `frame-update-inputs-appear` |
| FrameContract text inputs | Text input on `:replace` renders (label, `type="text"`, default); a form change sends `{:event, id, %{value: "Joan", type: :change}}` to the destination; a second input arrives by `:append`; both values render and `Session.get_data/1` has both in `input_infos` | both requirements |

The ticket is one sentence ("show up blank until I interact"). The requirements state what it leaves implicit: replace and append, nested frames, text and number inputs, sibling outputs kept, values tracked in session data (`input_infos`, the existing field the check reads), change events and edited values surviving an append. They name no function or approach. The upstream helper return shape (`find_frame_outputs/2` returning `{output, cell}`) stays out of the contract, as before.

## Incomplete control

`incomplete.patch` = `legacy_partial_patch` with `file_only` on `lib/livebook/notebook.ex`: the reference's `notebook.ex` block alone (1421 bytes, sha256 `b63fdcd9d9fc06185898e5cf604d47dd8533460c312c65fc760509f5f166a9aa`).

Accurate description (replaces the old probe text "without initializing and rendering the updated inputs", which was wrong): it indexes frame-update outputs and changes `find_frame_outputs/2` to return `{indexed_output, cell}` pairs, but leaves both LiveView consumers and `Cell` input discovery unchanged. The session LiveView's frame-update handler still matches `{idx, frame}`, so `idx` binds the inner tuple and `"output-#{idx}"` raises. That crashes the session LiveView on any frame update. Recorded outcome: hidden fails all three starting failures plus the previously passing `outputs frame output update`, all with `exit` in phase `test`. Preservation fails `outputs frame output update`. It therefore still fails starting failures, as required. v2 `case.json` has no probe description field, so the corrected text lives only here.

## Preservation decision

Old: `mix test test/livebook_web/live/session_live_test.exs`.
New: `mix test test/livebook_web/live/session_live_test.exs test/livebook/session/data_test.exs`.

Both files exist at baseline `64dad900` (checked with `git show`).

- **Added: `test/livebook/session/data_test.exs`** (236 tests, `async: true`). `Session.Data.add_cell_evaluation_output` indexes outputs and discovers inputs through the same `Notebook`/`Cell` traversal the repair touches, and registers `input_infos`. A solver may well change that path. The suite is pure data transformation: no processes, `assert_receive`, sleeps, clocks or runtime evaluation. It is deterministic, so it adds no timing risk. The reference does not change `Session.Data`, and its traversal changes only affect `:frame_update` outputs, which this file never uses. The baseline file is identical in the fixed upstream tree, so the reference should pass it. Qualification must confirm that.
- **Excluded: `test/livebook/notebook_test.exs`.** Its `find_frame_outputs/2` tests (lines 532–555) pin the helper's old return shape. Upstream changed that shape and updated those tests (`upstream-tests.patch`). Preservation restores baseline tests, so the reference would fail them. Including the file would also make the helper shape a hidden requirement. `mix test` cannot exclude only that `describe` without tag filters, which would need a new permitted exclusion tag. The useful `add_cell_output/3 … frame update` test is lost with it. Coverage of that path stays with acceptance.
- **Excluded: `test/livebook_web/live/app_session_live_test.exs`** (6 tests). Every test deploys an app and waits on asynchronous app status and evaluation through `assert_receive`, with ExUnit's 1.5 s receive timeout from `test_helper.exs`. That is timing-sensitive on a 2-scheduler box. None of these tests sends a frame update, so they barely exercise the changed code.
- **Considered, excluded: `test/livebook/session_test.exs`** (102 `assert_receive`, runtime/process heavy). It uses `find_assets_in_output` but has no frame-update asset test. The cost and flake risk outweigh the coverage.

Residual risk: `data_test` runs concurrently with the async LiveView suite and adds a short CPU burst under `+S 2:2`. It also changes the seed-0 module order. Qualification rounds should show whether this affects `session_live_test` stability.

## Clarifications

They contain no host, machine, speed or timing text, so they are unchanged.

## Reviewer checks

- Confirm in the first qualification round that the empty patch and the reference pass `data_test.exs` on this image (Elixir 1.15.2 / OTP 26.0.2).
- `frame-update-inputs-work` names `input_infos`, the existing session-data field the check reads. Confirm that this counts as stating the visible contract, not a recipe.
