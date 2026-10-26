# livebook-pr-2663 — curator notes (not solver input)

Schema-v2 conversion only. Nothing was executed; outcomes cited below come from `verification/frozen-cases-2026-10-15/qualification-outcomes.json` (byte-identical fixtures; all three 2026-10-15 rounds matched it).

## Contract

- `starting_failures` = the empty-patch hidden failures in phase `test` (all AssertionError):
  - `ListStructureTest::test nested content retains its AST across decimal boundaries and repeated round trips`
  - `LongListTest::test three-digit numbered parents retain nested bullets and code over repeated formatting`
  - `MarkdownHelpersTest::test markdown_from_ast/1 properly indents nested lists when the parent list has double digit items` (the exact upstream test, added to `required`)
- `required` = the same three checks.

## Assertion mapping

| Check | Asserts | Requirement |
| --- | --- | --- |
| ListStructure | A 105-item list has bullets and grandchildren under 9/99 and fenced code under 10/100. Parse → format → parse keeps the AST (metadata stripped), and a second format is identical | `nested-content-keeps-structure` |
| LongList | Items 1–99, then `100.` with a bullet and `101.` with a code block indented 5 spaces. Formatting returns the exact input, and formatting again gives the same text | `long-list-output-format` |
| upstream double digit | Items 1–9, then `10.` with two bullets and `11.` with a code block indented 4 spaces. `reformat(markdown) == markdown` | `long-list-output-format` |

The ticket says only that nesting breaks. `long-list-output-format` states the exact-output rule the two exact-string checks enforce: for items numbered 10 or higher, nested content is indented to where the item's text starts. It deliberately says nothing about items 9/99 in long lists. The audited `extra-space-before-decimal-boundary` alternative, which indents 9/99 children one space further, satisfies every check and should stay acceptable.

## Incomplete control

`incomplete.patch` = `legacy_partial_patch` `replace`. It turns `number_of_digits(index + 1) + 2` into `min(number_of_digits(index + 1), 2) + 2` (1 occurrence verified; 1466 bytes, sha256 `8bbcfbf64943ad49a1ee14aecb601ca6e3551291dd3974d4e33f1d1a89fb7142`). Recorded outcome: hidden fails only `LongListTest::test three-digit …` (AssertionError, phase `test`), which is a starting failure. Preservation passes. It meets the v2 control rule.

## Preservation

Unchanged: `mix test test/livebook/live_markdown/markdown_helpers_test.exs`.

## Clarifications

They contain no host, machine, speed or timing text, so they are unchanged.

## Reviewer checks

- Confirm that the parenthetical examples in `long-list-output-format` ("four spaces under `10. `, five under `100. `") read as an output-format statement, not a repair recipe. Both exact-string checks enforce them.
