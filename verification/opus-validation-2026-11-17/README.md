# Opus 5.5 validation of the rewritten tickets, 2026-11-17

The [case corrections of 2026-11-13](../case-fixes-2026-11-13/README.md) rewrote the tickets of ash-pr-3031 and livebook-pr-2800 and left their Opus validation undone, because it needs the user's solver session. On 2026-11-17 the user opened that session and these attempts were made. They also supply what [ADR 0021](../../docs/adr/0021-give-each-case-a-token-allowance.md) needs for the two cases: how many tokens the validator generated on the text as released.

Each attempt is an unscored **dry attempt on one case**, started on the dashboard with Claude Code and Opus 5.5 at `xhigh`, and driven by `/solve-run` from the solver session in `~/eab-solver`. Kit `d4ce1731…`, Claude Code 2.1.321, benchmark `elixir-agent-benchmark-v6`. None of these runs is published or scored.

## Runs

| Run | Case | Outcome | Output tokens | Peak context |
| --- | --- | --- | ---: | ---: |
| `20261117-203932-eb834fc8` | livebook-pr-2800, escape test | Evaluation error. Opus 5.5's safeguards stopped the probe on its first reply (`[cyber]`): the probe asks the solver to try to leave its sandbox. No tool ran. The transcript shows that no MCP server's instructions reached the solver. | 0 | — |
| `20261117-204208-f3baa4e1` | ash-pr-3031 | **Passed** all four checks: 15 of 15 hidden tests, 117 preservation tests, its own 130 tests, 13 of them failing on the starting source. | 142,422 | 300,199 |
| `20261117-212559-9eb4605e` | ash-pr-3031 | **Passed** all four checks: 15 of 15 hidden tests, 117 preservation tests, its own 129 tests, 11 of them failing on the starting source. | 143,511 | 286,003 |
| `20261117-215740-042076e5` | livebook-pr-2800 | **Passed** all four checks: 67 of 67 hidden tests, 53 preservation tests, its own 55 tests, 3 of them failing on the starting source. | 34,540 | 74,187 |
| `20261117-220429-d6cc14d1` | livebook-pr-2800 | **Passed** all four checks: 67 of 67 hidden tests, 53 preservation tests, its own 56 tests, 4 of them failing on the starting source. | 31,186 | 85,435 |

Both cases now have the two Opus 5.5 passes the [curation workflow](../../docs/case-curation-loop.md) asks for after a case changes. Before the tickets were rewritten, Opus failed both cases in all three runs of its published series.

Peak context is the largest prompt any model call was sent plus that call's reply, read from the transcript's usage records. Both ash-pr-3031 passes went past 262,144 tokens, the context a local model gets, although neither was compacted. The livebook-pr-2800 passes stayed under a third of it.

Under [ADR 0021](../../docs/adr/0021-give-each-case-a-token-allowance.md)'s rule, twice the median of these output tokens, the allowances would be 285,933 tokens for ash-pr-3031 and 65,726 for livebook-pr-2800. No release declares them yet.

The escape test was not repeated with another model. Its transcript already shows the one thing a real attempt could have been lost to, a connector's instructions in the solver's context, and the kit and Claude Code version are those of the [escape test that passed on 2026-11-13](../harness-checks-2026-11-13/README.md).

## The assembled v6 series

On 2026-11-17 the user asked for Opus 5.5 to appear in `elixir-agent-benchmark-v6` from the attempts that exist, without a new full run. [`assemble-v6-series.exs`](assemble-v6-series.exs) builds that series, `f3c7588f601f…` in `results-page/results/`, entirely from files in this repository. It is not the record of two runs made on v6.

| Assembled run | 18 cases with identical files in v5 and v6 | ash-pr-3031 | livebook-pr-2800 | Passed |
| --- | --- | --- | --- | ---: |
| `opus-v6-assembled-1` | v5 run `20261027-183407-2bbea0a5` | `20261117-204208-f3baa4e1` | `20261117-215740-042076e5` | 20 of 20 |
| `opus-v6-assembled-2` | v5 run `20261027-204103-33348dcc` | `20261117-212559-9eb4605e` | `20261117-220429-d6cc14d1` | 19 of 20 |

The v5 runs are the first two of Opus's published v5 series, oldest first, and each takes the attempts on the rewritten cases in the order they were made. The second run fails vutuv-pr-1759 on one hidden test, as it did in v5. The third v5 run is not used: the rewritten cases have two attempts each.

What separates these from runs made on v6:

- **The instructions.** v6 tells the solver that changes outside the allowed paths are discarded. The October runs' instructions ended that sentence at the list of paths.
- **The grader.** v6 discards changes outside the edit area instead of rejecting the submission ([ADR 0017](../../docs/adr/0017-discard-changes-outside-the-edit-area.md)). None of the 36 carried outcomes depends on that: 35 passed under the stricter rule, and the one failure is a failed hidden test.
- **The harness.** The October runs used Claude Code 2.1.308 and kit `d0123be7…`, working on two cases at once. The attempts on the rewritten cases used 2.1.321 and kit `d4ce1731…`, one case at a time. The kits differ in one setting that keeps a chart plugin's server away from the solver.
- **The series it is.** Its setup carries an `assembled` entry, so a run made on v6 never joins it and starts Opus's real series instead. The assembled one stays at two runs of three, and should be removed once the real series exists.

Each case's peak context is read from the saved transcripts, here and in [the October record](../opus-validation-2026-10-26/README.md). The series' note on the results page and the v6 release note both say it is assembled.

## What is kept

Each run folder holds the hook decision log, and per case a grade summary, the sealed patch and a `logs/` folder with the attempt's full logs: the controller's `activity.log`, the solver's `claude-transcript.jsonl` and the grader's `grade.json`. The Claude organization ID is replaced with `[redacted organization]`, and the user's email address would be replaced with `[redacted email]`; these transcripts carry none. Nothing else is changed. The grade summaries add each attempt's stop reason, model calls, output tokens and peak context.

## Reviews

Both ash-pr-3031 patches were read against the ticket and the reference. They are two different implementations of one idea: a literal argument that sits beside an expression argument is marked as already cast, so nothing casts, constrains or coerces it again. Each adds one new test file and changes no existing test, and neither has anything in its library code that refers to tests or the grader. The saved patch and grade of each match their sealed receipts, and both ran under the same settings, kit and prepared image.

Both livebook-pr-2800 patches convert the Erlang error text as Unicode character data instead of raw bytes, which is the non-ASCII rule the ticket now names, and both keep the snippet in the form the running Elixir version expects. They differ in code. Each extends the existing evaluator test file: the only lines removed are four or five loose `assert_receive` calls, replaced by stricter ones. Neither has anything in its library code that refers to tests or the grader, and the saved patch and grade of each match their sealed receipts.

## Departures from the curation workflow

- The attempts ran as dry attempts inside the full twenty-case release, not as ordinary validation runs on an inventory holding one case. The case files, prompt, harness and grader are the same.
- The second attempt at each case was started before the first patch had been reviewed. The reviews, done while it ran, found nothing.
