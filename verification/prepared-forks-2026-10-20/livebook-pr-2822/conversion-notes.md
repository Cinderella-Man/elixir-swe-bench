# livebook-pr-2822 — v2 conversion notes (curator only, not solver input)

## Conversion

- `case.json` follows the same v2 conversion as 2800: legacy fields removed, `grading` added. Commands, clarifications and the protected files are unchanged.
- New `incomplete.patch` and `integrity.patch` files. The integrity patch is the exact legacy halt text.

## starting_failures (2) and required (2)

- Source: `qualification-outcomes.json`, `empty_patch.hidden`, failures in phase `test`. The stage completed.
- The identity file hashes equal this draft's files. Tree `f27e5b87…` matches `provenance.broken_tree`.
- Added to `required`: `Elixir.Livebook.Runtime.EvaluatorTest::test evaluate_code/6 identifier tracking context merging with errored evaluation`.
  - This is the exact upstream test. It fails in the test body on the starting source but was never in the legacy required list.

## incomplete.patch

- Rebuilt from legacy probe `replace` x1: `+            pdict: context.pdict` becomes `+            pdict: %{}`. This keeps the imports and discards the process dictionary.
- Computed with Python bytes (occurrence count 1) and recomputed with Perl, byte-identical. sha256 `9c0716dc…`. The only diff from `reference.patch` is line 22.
- The recorded `partial_repair` control failed both starting failures in the test body. The probe in its identity is the same.

## Why the failure happens (curator context only)

- On the starting source, a failed evaluation stores a fresh `initial_context()`.
- `merge_context` takes the later context's process dictionary and its imported functions and macros wholesale.
- So a failed evaluation in the parent chain wipes the earlier imports and process dictionary. None of this is in solver text.

## Assertion map

| Check (acceptance.patch lines) | Asserted | Requirement |
| --- | --- | --- |
| FailedContext 154-155 | the failed cell still returns its error | failed-cell-leaves-no-state |
| FailedContext 157-163 | the failed context's own fields (see list below) | failed-evaluation-context |
| FailedContext 164 | the failed cell's module is not loaded | failed-cell-leaves-no-state |
| FailedContext 166-177 | parent `[:bad]` alone: imports usable; `:prior`/`:keep` kept; `:introduced` nil | both |
| FailedContext 179-181 | parents `[:bad, :good]`: earlier binding; alias is Map, not MapSet | failed-cell-leaves-no-state |
| FailedContext 183-185 | `assert false`, then `assert true` and pdict still work | failed-cell-leaves-no-state |
| Upstream EvaluatorTest 67-83 | context `[1]`: binding, aliases, requires, imports, vars, modules, pdict | failed-evaluation-context |
| Upstream EvaluatorTest 87-104 | merged `[1, 0]` equals eval 0's state, including pdict `x:1, y:1, z:1` | failed-cell-leaves-no-state |

The fields checked at FailedContext 157-163:
- imports are exactly the prior ones (order-insensitive);
- `pdict` equals the prior `pdict`;
- `binding` and `aliases` are both `[]`;
- MapSet is not required;
- `context_modules` is `[]`.

Context `[1]` in the upstream test (lines 67-83):
- `binding` and `aliases` are both `[]`;
- neither Map nor Enum is in `requires`;
- Integer imports have at least 2 entries;
- `versioned_vars` is `%{}` and `context_modules` is `[]`;
- `pdict` equals eval 0's.

Upstream line 10 loosens the `eval` helper from `terminal_text(_)` to any output, so the errored evaluation can be awaited.

Both of the brief's points are now explicit:
1. Rollback, with later evaluations seeing exactly the earlier state.
2. The failed evaluation's own recorded context is empty apart from the carried-forward imports and process dictionary.

This closes the gap the freeze audit flagged: one recorded local-model failure kept bindings in the failed context.

## Doubts for the reviewer

- **Named observation point.** `failed-evaluation-context` names `Livebook.Runtime.Evaluator.get_evaluation_context/2`. That is the public, documented function the visible evaluator tests already use, so it is where the outcome is observed, not something to change. Drop the name if it reads as a hint.
- **Shape of the fix.** "imports and process dictionary are exactly those in effect before the failed cell ran" describes the observable shape of the upstream fix. The checks cannot pass without it, and the brief asked for it.
- **Requires wording.** The text says "none of the requires added by the failed cell or by earlier cells", not "no requires", because the tests only check that specific modules are absent. The reference produces `[]`.
- **Overlapping mappings.** Both requirements map to both tests. Overlap is permitted, as in accent's template.
