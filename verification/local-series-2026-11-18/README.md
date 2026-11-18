# Local models on v6: full logs, DeepSeek's peak context and the ISTA run, 2026-11-18

On 2026-11-18 the user asked for the local models' runs to keep their full logs the way the Claude Code runs do ([Opus](../opus-validation-2026-11-17/README.md), [Sonnet](../sonnet-series-2026-11-17/README.md), [Haiku](../haiku-series-2026-11-17/README.md)), so that later questions can be answered from data that already exists. This is the record of the four full runs local models have made on `elixir-agent-benchmark-v6`, each through the Pi harness with a 262,144-token context window, working on one case at a time. Their logs are in [`verification/runs/`](../runs/), one folder per run, written by the code that **Add to results page** has used since that day ([ADR 0023](../../docs/adr/0023-keep-every-published-runs-full-logs.md)).

Two of the runs were made by the controller on this repository's machine. The other two were made by a second controller on another machine, which still held all their files. Nothing was run or graded again for anything here.

## Runs

| Run | Model | Thinking | Passed | Cut off, context full | Model calls | Output tokens | Made by |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| [`20261113-193538-5205670a`](../runs/run-20261113-193538-5205670a/) | DeepSeek-V4.1-Flash-1017, Unsloth UD-IQ1_M | high | 17 of 20 | 1 | 1,248 | 773,439 | The second controller |
| [`20261114-085614-515bd299`](../runs/run-20261114-085614-515bd299/) | DeepSeek-V4.1-Flash-1017-GSQ-RCO-Coder, ISTA DASLab IQ2_XXS | high | 15 of 20 | 4 | 1,791 | 1,076,236 | The second controller |
| [`20261116-113511-21de1916`](../runs/run-20261116-113511-21de1916/) | Qwen3.8-27B, Unsloth UD-Q6_K_L v3.1 | xhigh | 16 of 20 | 4 | 2,397 | 1,599,358 | This machine's controller |
| [`20261117-072245-3bd94d5c`](../runs/run-20261117-072245-3bd94d5c/) | Qwen3.8-27B, Unsloth UD-Q4_K_XL v3.1 | xhigh | 18 of 20 | 3 | 2,300 | 1,423,381 | This machine's controller |

All four used the case files v6 has today: each run's recorded hashes of every case's files equal the current ones. Each is the first run of its series, with seed 101.

Cases failed, and cases cut off when the context was full (a cut-off attempt's patch is still graded, so it can pass):

| Model | Failed | Cut off |
| --- | --- | --- |
| DeepSeek UD-IQ1_M | ash-pr-3031, beacon-pr-687, vutuv-pr-1759 | ash-pr-3031 |
| DeepSeek GSQ-RCO-Coder IQ2_XXS | absinthe-pr-1176, ash-pr-3031, beacon-pr-687, livebeats-pr-37, vutuv-pr-1759 | absinthe-pr-1176, ash-pr-3031, pinchflat-pr-610, vutuv-pr-1759 |
| Qwen3.8-27B UD-Q6_K_L | absinthe-pr-1176, accent-pr-183, ash-pr-3031, vutuv-pr-1759 | absinthe-pr-1176, ash-pr-3031, beacon-pr-687, vutuv-pr-1759 |
| Qwen3.8-27B UD-Q4_K_XL | ash-pr-3031, vutuv-pr-1759 | absinthe-pr-1176, beacon-pr-687, vutuv-pr-1759 |

## Scores at context sizes

Cases solved, of 20, with the whole attempt inside each size ([how these scores work](../../docs/context-size-scoring.md)). Each attempt's peak context is the largest prompt any of its model calls was sent, plus that call's reply.

| Model | 65,536 | 98,304 | 131,072 | 196,608 | 262,144 | As run | Median peak |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| DeepSeek UD-IQ1_M | 4 | 10 | 15 | 16 | 17 | 17 | 91,574 |
| DeepSeek GSQ-RCO-Coder IQ2_XXS | 3 | 5 | 10 | 14 | 14 | 15 | 128,609 |
| Qwen3.8-27B UD-Q4_K_XL | 5 | 9 | 13 | 16 | 16 | 18 | 104,156 |
| Qwen3.8-27B UD-Q6_K_L | 2 | 7 | 11 | 14 | 15 | 16 | 116,398 |

## DeepSeek's peak context

The DeepSeek UD-IQ1_M run was published on 2026-11-14, three days before attempts began recording their peak context ([ADR 0022](../../docs/adr/0022-score-runs-at-context-sizes.md)), so the results page could not show it at a context size. Its 1,248 model calls each left a usage record with the tokens of the prompt and of the reply. [`calls.json`](../runs/run-20261113-193538-5205670a/calls.json) in the run's folder lists them, and [`add-deepseek-peak-context.exs`](add-deepseek-peak-context.exs) adds each case's peak to the published series, `75a9990dffea…`, and brings it to public schema 12.

The script refuses to write unless every case has exactly as many calls as its published `model_calls` and their reply tokens add up exactly to its published `generated_tokens`. All twenty cases do. No outcome, token count or other published number changed.

At 131,072 tokens DeepSeek UD-IQ1_M solves 15, the most of any v6 series; Opus 5.5 and Qwen3.8-27B UD-Q4_K_XL solve 13. It solves absinthe-pr-1176 at a peak of 243,275 tokens, where Opus needs about 300,000.

## The ISTA run

The second controller also held a finished v6 run that had never been published: the same DeepSeek model in ISTA DASLab's GSQ-RCO-Coder IQ2_XXS quant, made on 2026-11-14 under the same release and settings as the UD-IQ1_M run of the day before. This model has a [v5 series](../../results-page/releases/v5/) of one run. At the user's request the run is now series `236af9a397a6…` in `results-page/results/`, built from the run's own record by the code that publishes any run, with its peaks read from its usage records.

- **Its thinking level is published as `high`.** The run was started with `xhigh` declared. The model host served this model with its `high` preset, the model's v5 series is published as `high`, and the user corrected the same declaration on the UD-IQ1_M run by hand on 2026-11-14. The user confirmed `high` for this run on 2026-11-18.
- **Its model files are named, not hashed.** The run predates [ADR 0018](../../docs/adr/0018-declare-and-hash-model-sources.md): the model host reported the served files' names and sizes, and the record has no download link or file hashes.
- **Its times are the ones the second controller recorded**, as for the UD-IQ1_M run. The model was served on a third machine.

## What is kept

Each run's folder in `verification/runs/` holds:

- **`run-summary.json`:** what was run: the release, every case file's hash, the harness, the model and its declared source, the settings and the score.
- **`calls.json`:** the prompt and output tokens of every model call of every case, in call order. Each attempt's peak context can be recomputed from it.
- **Per case:** the instructions the agent was given, the patch as submitted, a grade summary and a `logs/` folder with the controller's `activity.log`, the agent's event stream `pi-events.jsonl` (every message, reasoning block, tool call and tool result) and the grader's `grade.json`.
- **`manifest.json`:** every file with its size and SHA-256.

The files are copied unchanged. The export replaces the model host's names wherever they occur; these runs' logs held none, so nothing was replaced. They were also searched for other network addresses, keys and email addresses, and hold none.

Left out: the controller's copies of every request and response (about 1.3 GB per run, and the same conversation the event stream holds), each call's timing, and the runs' raw records, which name the machines.

## Checks made

- Every `grade.json` matches the hash its attempt sealed: 80 of 80.
- Every case's calls match its published record: the number of calls, the reply tokens summed, the peak context and the outcome, in all four runs.
- The copies from the second controller are the files as it serves them; the patches and logs of those two runs have no sealed hash to compare with.
- Each folder matches its manifest, and the folder the dashboard button wrote for run `20261117-072245-3bd94d5c` is identical, file for file, to one written from the same run outside the controller.

The patches of these runs were not reviewed.
