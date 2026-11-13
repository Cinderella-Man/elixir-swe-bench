# Case corrections after the run audit, 2026-11-13

Before running about fifty more models, the user asked for an audit of the harness, the cases and the recorded runs, and then for what it found to be fixed. The audit read every graded attempt in the controller's history (313 attempts in 37 runs) and the twelve published series. Six cases stood out because every failing model failed the same hidden test. Independent readers compared those tests with the text the solver sees, the failing patches and the passing ones.

## What the audit found in the cases

| Case | Finding | Decision |
| --- | --- | --- |
| livebook-pr-2800 | Three required hidden tests need Erlang error descriptions with non-ASCII characters to be converted correctly. That is a curator extension to the upstream fix, and every example in the solver's text was ASCII. On the frozen release Opus 5.5 failed exactly those three tests in 3 of 3 published runs, local models in 6 of 6 recorded attempts; only Sonnet 5.5 passed (2 of 2), by probing inputs the text did not name. | The requirement and the ticket now name non-ASCII code. No check, reference or mapping changed. |
| ash-pr-3031 | No attempt has passed since its checks were last strengthened (0 of 15 graded attempts; all nine Claude attempts stop at 13 of 15). Two required tests fail only for a solution that casts, constrains or coerces a literal argument a second time, which matters only for a type whose cast does not accept or preserve its own output. The text said such values must "retain their values" and never named that trigger. | The ticket and the `valid-arguments` requirement now state the rule, scoped to a calculation that also receives an expression argument and to loads and filters, which is what the reference does. No check, reference or mapping changed. |
| guardian-pr-748 | Both published Sonnet 5.5 runs were rejected untested because the patch edited `README.md`, which is outside the case's edit paths, although the ticket welcomes documentation updates. Re-graded without the README change, both patches pass every check. | The case is unchanged. The grader now discards changes outside the edit area instead of rejecting the submission ([ADR 0017](../../docs/adr/0017-discard-changes-outside-the-edit-area.md)). |
| accent-pr-183, beacon-pr-687, plausible-pr-6449, vutuv-pr-1759, cachex-pr-341 | The consistently failed check follows from a stated requirement in each. The failing patches miss it; the passing ones did not have to guess. | Unchanged. Two optional wording improvements are recorded below. |

ADR 0012's third amendment says Opus failed livebook-pr-2800 on "the non-ASCII text the ticket names". The ticket named none until this batch.

## Changes

| Case | File | Change |
| --- | --- | --- |
| livebook-pr-2800 | `ticket.md` | "…; fix it, including when the offending code contains non-ASCII characters." |
| livebook-pr-2800 | `case.json`, requirement `erlang-syntax-error-report` | Adds: all of it also holds when the offending code contains non-ASCII characters, as in `X = 'ö' 'ü'.`, `X = 'ł' 'ł'.` or the unterminated `X = 'ł`; the message is still the SyntaxError and its description quotes those characters as written. |
| ash-pr-3031 | `ticket.md`, second paragraph | Beside an expression argument, literal arguments are cast and constrained once and the calculation uses exactly that value when loaded or filtered; it must not be cast, constrained or coerced a second time, because a type's cast need not accept or preserve its own output. |
| ash-pr-3031 | `case.json`, requirement `valid-arguments` | The same rule, replacing "this includes typed comparisons within calculation expressions". |

Every other file of both bundles is byte-identical to the released version. The eighteen other cases are untouched.

## Evidence

- **Independent review:** a reviewer with a fresh context read the texts before the tests and approved each draft against its exact file hashes (`<case>/independent-review.json`). For ash-pr-3031 the reviewer traced the reference: beside an expression argument a literal is validated once and stored as an already-cast value that operators and evaluation leave alone, in loads and in developer filters; without an expression sibling the reference still coerces it, and sorts are neither tested nor claimed, so the new text claims neither.
- **Qualification:** each case passed three fresh qualification rounds with identical named outcomes under the grader of this commit, `cfb152063f1a…` (`<case>/qualification-round-{1,2,3}.json`, `<case>/prepared-source-tree.json`). The checks and references did not change, so the controls are the released ones run again: ash-pr-3031 fails its 11 starting failures of 15 hidden tests on the starting source and livebook-pr-2800 its 14 of 67, and both references pass.
- **guardian-pr-748 under the new grader:** both Sonnet 5.5 patches, graded as submitted from runs `20261028-065746-940e9ba4` and `20261028-133546-8d515727`, now pass every check with `README.md` recorded as discarded. Four saved submissions for unchanged cases re-graded to their recorded verdicts with no test result changed.
- **Exported bundles:** each is exactly its reviewed draft plus its admission receipt.

## Not done here: Opus validation

The [curation workflow](../../docs/case-curation-loop.md) asks for two reviewed Opus 5.5 passes through the Claude Code harness after a case changes. Those runs need the user's solver session and were not made. Until they are, livebook-pr-2800 and ash-pr-3031 are corrected and qualified, not validated. ash-pr-3031 in particular has one recorded pass ever (Astra, 2026-10-20, before the last strengthening); whether the clearer text makes it passable is what its validation attempts will show.

## Left as they are

- **accent-pr-183:** the hidden test uses the compound requirement `>= 1.1.0 and < 1.2.0`. The text says "a semantic version requirement such as `~> 1.1`" and never shows a compound one. Every pass used Elixir's own `Version`, which accepts it; every failure hand-rolled a parser. Naming the grammar would remove the residual doubt.
- **vutuv-pr-1759:** a NUL byte in `q` or `handles` must match nothing. That follows from "any text in `q` or `handles`", but NUL is not named, and the reference itself returned an error for it until the second validation review.
- **cachex-pr-341:** a test that names a warmer with a literal `name:` cannot compile on the starting source, so it does not count as a regression test. The rule is stated twice; satisfying it for this feature needs a record built at run time.

## Status

- **Release:** benchmark `elixir-agent-benchmark-v6`, twenty cases. The controller's inventory matches the checkout and every admission verifies. The eighteen cases this batch did not touch are byte-identical to before.
- **Whole inventory under the new grader:** after the restore, the controller prepared and qualified all twenty cases under grader `cfb152063f1a…`. In each, the reference passes and the unchanged source, the partial fix and the bypass are rejected.
- **Published results:** the twelve v5 series moved to `results-page/releases/v5/` and stay the results page's primary release; new runs are published to v6 in `results-page/results/`.
- **Forks:** unchanged. No source, reference or preparation changed.
