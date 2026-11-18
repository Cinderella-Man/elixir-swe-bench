# Sonnet 5.5 on the rewritten tickets, and its assembled v6 series, 2026-11-17

On 2026-11-17 the user asked for Sonnet 5.5 to be brought into `elixir-agent-benchmark-v6` the way [Opus 5.5 was](../opus-validation-2026-11-17/README.md#the-assembled-v6-series): keep its v5 outcomes for the 18 cases whose files did not change, and attempt the two cases whose tickets v6 rewrote twice each. This folder holds those four attempts, the re-grade one carried case needed, and the script that assembles the series.

Each attempt is an unscored **dry attempt on one case**, made one at a time with Claude Code and Sonnet 5.5 at `max` effort, kit `d4ce1731…`, Claude Code 2.1.321. They ran overnight from the user's solver session in `~/eab-solver`.

## Attempts

| Run | Case | Outcome | Output tokens | Peak context |
| --- | --- | --- | ---: | ---: |
| `20261117-224148-3918a9b8` | livebook-pr-2800 | **Passed** all four checks: 67 of 67 hidden tests, 53 preservation tests, its own 57 tests. | 127,148 | 212,577 |
| `20261117-230447-55568d0f` | livebook-pr-2800 | **Passed** all four checks: 67 of 67 hidden tests, 53 preservation tests, its own 57 tests. | 135,546 | 206,584 |
| `20261117-233204-7b2bd497` | ash-pr-3031 | **Passed** all four checks: 15 of 15 hidden tests, 117 preservation tests, its own 155 tests. | 332,319 | 600,702 |
| `20261118-003552-5e45f12f` | ash-pr-3031 | **Passed** all four checks: 15 of 15 hidden tests, 117 preservation tests, its own 160 tests. | 379,392 | 722,131 |

Every attempt ended with the agent finishing on its own and without compaction. Both ash-pr-3031 attempts generated more than the 262,144 output tokens the instructions declare, which Claude Code cannot enforce; they are flagged for it, not failed. Sonnet had failed ash-pr-3031 in both v5 runs.

The patches were checked mechanically, not read line by line: each saved patch and grade matches its sealed receipt, the stored logs are identical to the controller's, and no line of library code in any patch refers to tests or the grader.

## guardian-pr-748, re-graded

In v5 both of Sonnet's guardian-pr-748 patches were rejected before any test ran, because each also edited `README.md`, outside the case's edit paths. v6 discards such edits and grades the rest ([ADR 0017](../../docs/adr/0017-discard-changes-outside-the-edit-area.md)). On 2026-11-18 both patches, as saved in October, were graded again by the v6 controller:

| v5 run | Patch | Result under v6 |
| --- | --- | --- |
| `20261028-065746-940e9ba4` | `0d0127d4…` | **Passed**: 23 of 23 hidden tests, 155 preservation tests, its own 268 tests; `README.md` discarded |
| `20261028-133546-8d515727` | `d98597a8…` | **Passed**: 23 of 23 hidden tests, 155 preservation tests, its own 291 tests; `README.md` discarded |

The patch hashes are the ones [the October record](../sonnet-series-2026-10-28/README.md) lists. The full grader output is in [`guardian-regrade/`](guardian-regrade/).

## The assembled v6 series

[`assemble-v6-series.exs`](assemble-v6-series.exs) builds series `b6f2e9a0c441…` in `results-page/results/`, entirely from files in this repository. It is not the record of two runs made on v6.

| Assembled run | 18 cases with identical files in v5 and v6 | ash-pr-3031 | livebook-pr-2800 | Passed |
| --- | --- | --- | --- | ---: |
| `sonnet-v6-assembled-1` | v5 run `20261028-065746-940e9ba4` | `20261117-233204-7b2bd497` | `20261117-224148-3918a9b8` | 20 of 20 |
| `sonnet-v6-assembled-2` | v5 run `20261028-133546-8d515727` | `20261118-003552-5e45f12f` | `20261117-230447-55568d0f` | 20 of 20 |

Sonnet's v5 series has two runs, and each takes the attempts on the rewritten cases in the order they were made. guardian-pr-748 carries its re-graded verdict in both.

What separates these from runs made on v6:

- **The instructions.** v6 tells the solver that changes outside the allowed paths are discarded. The October runs' instructions ended that sentence at the list of paths.
- **The grader.** Of the 36 carried outcomes, 34 passed under v5's stricter rule and pass unchanged. The other two are guardian-pr-748, re-graded above.
- **The harness.** The October runs used Claude Code 2.1.308 and kit `d0123be7…`, working on two cases at once. The attempts on the rewritten cases used 2.1.321 and kit `d4ce1731…`, one case at a time. The kits differ in one setting that keeps a chart plugin's server away from the solver.
- **The series it is.** Its setup carries an `assembled` entry, so a run made on v6 never joins it and starts Sonnet's real series instead. The assembled one stays at two runs of three, and should be removed once the real series exists.

Sonnet at `max` effort needs far more context than a local model gets. Read at 262,144 tokens of context, the two assembled runs solve 9 and 7 of 20; as run they solve all 20. See [how scores at context sizes work](../../docs/context-size-scoring.md).

## What is kept

Each run folder holds the hook decision log, and per case a grade summary, the sealed patch and a `logs/` folder with the attempt's full logs: the controller's `activity.log`, the solver's `claude-transcript.jsonl` and the grader's `grade.json`. The Claude organization ID is replaced with `[redacted organization]`; these transcripts carry no email address. Nothing else is changed.
