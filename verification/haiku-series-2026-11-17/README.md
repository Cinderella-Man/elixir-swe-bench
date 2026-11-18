# Haiku 5.5 series on v6, 2026-11-18

Two ordinary full runs of `elixir-agent-benchmark-v6` with Haiku 5.5 at `max` effort through the [Claude Code harness](../../docs/adr/0010-run-subscription-claude-through-claude-code-harness.md), made overnight on 2026-11-18 at the user's request from the solver session in `~/eab-solver`. They are the first two runs of Haiku's v6 series, `3ed14e38d46b…` in `results-page/results/`. Unlike [Opus's](../opus-validation-2026-11-17/README.md#the-assembled-v6-series) and [Sonnet's](../sonnet-series-2026-11-17/README.md#the-assembled-v6-series) v6 series, nothing here is assembled: each run attempted all twenty cases on v6.

Both runs worked on two cases at once, with kit `d4ce1731…` and Claude Code 2.1.321. No elapsed times were recorded.

## Runs

| Run | Passed | Failed | Output tokens | Model calls |
| --- | ---: | --- | ---: | ---: |
| `20261118-014748-333885a9` | 19 of 20 | beacon-pr-687: one hidden test, "routes and scopes declared after beacon_sitemap_index/1 keep working" | 3,569,960 | 1,881 |
| `20261118-052028-4e88649d` | 19 of 20 | ash-pr-3031: one hidden test, "custom type callback rejections become input errors across loads filters and sorts" | 3,638,053 | 2,094 |

Every attempt of both runs ended with the agent finishing on its own, with no compaction, no evaluation error and no safety stop. Each failure is a single failed hidden test with every other check passing; neither case failed in the other run.

Six attempts generated more than the 262,144 output tokens the instructions declare, which Claude Code cannot enforce: absinthe-pr-1176 and ash-pr-3031 in both runs, and beacon-pr-687 and vutuv-pr-1759 in the second. They are flagged for it, not failed.

## Context

Haiku at `max` effort uses a great deal of context. Each attempt's peak context, the largest prompt any model call was sent plus that call's reply:

| Run | Smallest | Median | Largest | Over 262,144 |
| --- | ---: | ---: | ---: | ---: |
| `20261118-014748-333885a9` | 112,870 | 290,899 | 548,248 | 10 of 20 |
| `20261118-052028-4e88649d` | 124,993 | 266,597 | 570,480 | 10 of 20 |

Read at 262,144 tokens of context, each run solves 10 of 20; at 131,072, 2 of 20. See [how scores at context sizes work](../../docs/context-size-scoring.md).

## What is kept

Each run folder holds the hook decision log, and for each of its twenty cases a grade summary, the sealed patch and a `logs/` folder with the attempt's full logs: the controller's `activity.log`, the solver's `claude-transcript.jsonl` and the grader's `grade.json`. The Claude organization ID is replaced with `[redacted organization]`; these transcripts carry no email address. Nothing else is changed. The grade summaries add each attempt's stop reason, model calls, output tokens and peak context.

The patches of these runs were not reviewed.
