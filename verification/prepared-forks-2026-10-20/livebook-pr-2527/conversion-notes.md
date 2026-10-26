# livebook-pr-2527 — curator notes (not solver input)

Schema-v2 conversion of the legacy bundle. Nothing was executed; outcomes cited below come from `verification/frozen-cases-2026-10-15/qualification-outcomes.json` (byte-identical fixtures; all three 2026-10-15 rounds matched it).

## BLOCKER: the legacy incomplete control does not meet the v2 control rule

`incomplete.patch` was built exactly as the conversion rules require: `legacy_partial_patch`, a `replace` that changes `only_stamp_data(rest_source)` to `:error`, with 1 occurrence verified. The patch is 1793 bytes, sha256 `62140b42bb66fe67d3965063cafa0d7fe97fb95278cbe9c52829dd40479285c9`. Its recorded hidden failures are:

- `StampContractTest::test a freshly signed unicode notebook and harmless stamp whitespace verify`
- four existing `ImportTest` positive-stamp tests (personal v1/v2, offline hub, file-entry quarantine)

None of these is a starting failure. Rejecting every stamp makes all three starting-failure checks pass. `Grader.valid_controls?/5` requires `Enum.any?(partial_failures, &(&1 in starting))` whenever `starting_failures` is non-empty, and v2 requires it to be non-empty. **This bundle will therefore fail qualification as drafted.** The two rules (byte-identical legacy patch; incomplete control fails a starting failure) cannot both hold for this case. The controller or user must choose.

Suggested replacement, not applied: the executed audit mutant `reject-elixir-fences-only` (`verification/task-quality/cases/livebook-pr-2527/audit.json`). It is a plausible partial repair that rejects the stamp only when literal Elixir fences follow the signed offset. In `docs/verification/task-quality-promotion-evidence-2026-10-14.json` (cases[6].variants[0]), hidden failed only `StampContractTest::test inserted erlang code is imported without retaining stamp authorization`, in phase `test`. That is a starting failure. Preservation passed 43/43. The replacement is the reference with one line changed. It is 1819 bytes, sha256 `d3af04aac7af221956615ed5ee9b781e181e2c6edfa883e20657e1de34837b8e`, and `git apply --check` succeeds against the baseline:

````diff
-+           {:ok, ^stamp_data} <- only_stamp_data(rest_source),
++           true <- not String.contains?(rest_source, "```elixir"),
````

(i.e. `reference.patch` with `{:ok, ^stamp_data} <- only_stamp_data(rest_source),` → `true <- not String.contains?(rest_source, "```elixir"),`, exactly one occurrence). Adopting it changes the control's meaning: it would no longer exercise over-rejection. Over-rejection stays covered as a required check by `valid-stamps-still-verify` and by preservation.

## Contract

- `starting_failures` = the empty-patch hidden failures in phase `test`:
  - `StampContractTest::test inserted elixir code …` (AssertionError)
  - `StampContractTest::test inserted erlang code …` (AssertionError)
  - `ImportTest::test notebook stamp treats stamp as invalid when there is additional content after offset` (MatchError, the exact upstream test, added to `required`)
- `required` = these three plus `StampContractTest::test a freshly signed unicode notebook and harmless stamp whitespace verify` (passes on the empty patch).

## Assertion mapping

| Check | Asserts | Requirement |
| --- | --- | --- |
| inserted elixir / erlang | An Elixir or Erlang cell is inserted between the exported body and its stamp. The stamp is not verified, `hub_secret_names == []`, some warning contains the personal-hub text, and the added cell is imported with its exact source | `altered-notebook-unverified` |
| upstream treats-as-invalid | The fixed v2 fixture with an extra Elixir cell after the offset gives `warnings: [message]` (exactly one) matching "…environment variables defined in this machine", `stamp_verified?: false` and no secret names | `altered-notebook-unverified` |
| freshly signed + whitespace | An exported "Café notebook" with a secret, and the same notebook with `"\n \t\n"` inserted before the stamp, both verify with `warnings == []` and the secret restored | `valid-stamps-still-verify` |

What the requirements make explicit beyond the ticket:

- added cells are still imported, so dropping them is not a fix;
- exactly one warning, reusing the existing failure message;
- non-ASCII signed content;
- the whitespace rule.

The whitespace sentence is the agreed decision from the 2026-10-26 freeze audit. The upstream fix trims the suffix (`reference.patch:33`), so a repair that verifies every byte up to the stamp would otherwise fail without notice.

## Preservation

Unchanged: `mix test test/livebook/live_markdown/import_test.exs`.

## Clarifications

They contain no host, machine, speed or timing text, so they are unchanged.

## Reviewer checks

- Resolve the blocker above before qualification.
- `altered-notebook-unverified` quotes part of the personal-hub warning. It is the existing message in `import.ex` (`@personal_stamp_message`), not new wording.

## Curator decision: incomplete control (2026-10-26)

The legacy "reject every stamp" probe fails no starting failure, so it cannot satisfy the v2 control rule that the incomplete patch fail at least one starting failure. `incomplete.patch` is therefore the executed audit mutant `reject-elixir-fences-only`: the reference with `only_stamp_data(rest_source)` replaced by `true <- not String.contains?(rest_source, "```elixir")`. It is a plausible partial repair that rejects inserted Elixir code but misses inserted Erlang code; the promotion evidence recorded it failing only `inserted erlang` in a test body while preservation passed. SHA-256 `d3af04aac7af221956615ed5ee9b781e181e2c6edfa883e20657e1de34837b8e`.
