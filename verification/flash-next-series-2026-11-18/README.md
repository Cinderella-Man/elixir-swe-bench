# Qwen3.8 Flash Next UD-IQ2_XS: its assembled v6 run, 2026-11-18

On 2026-11-18 a full v6 run of Qwen3.8 Flash Next, Unsloth's UD-IQ2_XS v3.1 quant on Strata through Pi, finished with one evaluation error. The same evening that case was run again on its own, and passed. The user asked for the two to be merged and published like any other model's results, and chose an assembled series, like [Opus's](../opus-validation-2026-11-17/README.md#the-assembled-v6-series) and [Sonnet's](../sonnet-series-2026-11-17/README.md#the-assembled-v6-series), over joining the model's real series. This folder holds the script that builds it.

## The two runs

| Run | What it is | Cases | Outcome | Logs |
| --- | --- | ---: | --- | --- |
| `20261118-115818-69764904` | Full run, seed 101 | 20 | 18 passed, ash-pr-3031 and vutuv-pr-1759 failed, beacon-pr-687 an evaluation error | [run-20261118-115818-69764904](../v6-archive-2026-11-19/runs/run-20261118-115818-69764904/) |
| `20261118-184224-6d451a46` | One-case rerun of beacon-pr-687 from that run | 1 | **Passed** all required checks | [run-20261118-184224-6d451a46](../v6-archive-2026-11-19/runs/run-20261118-184224-6d451a46/) |

beacon-pr-687 produced no outcome in the full run. After 102 model calls the agent ran `rm -rf lib && cp -r /tmp/lib-current/lib lib`. Its earlier copy had put the folder's contents straight into `/tmp/lib-current`, so the copy back failed and `lib/` was gone. The harness saves the patch after every tool call. The diff deleting every file in `lib/`, about 1.6 MB of source, was over the 1 MiB patch limit, and the failed save ended the attempt. The agent's code was lost with the workspace. Since commit `4ba807da` a snapshot that cannot be saved keeps the previous one and the attempt goes on. The rerun ran on a controller with that fix.

The rerun matches the full run in everything a run series compares: the model file (`unsloth/Qwen3.8-Flash-Next-GGUF` at commit `f5d175d`, v3.1), Strata 0.1.61 with one slot, its chat template and sampling defaults, the settings (thinking at `xhigh`, a 262,144-token window, no other caps, seed 101), Pi 1.2.0, one case at a time, the case files and the frozen release apart from its code. Only the benchmark code differs: release `5f626b95…` with code `8bc26f09…` for the full run, release `fde3f77e…` with code `691504cf…` for the rerun. That change also made the controller check beacon-pr-687's fixtures again before the rerun started, because the changed file is one the fixture check hashes.

## The assembled run

[`assemble-series.exs`](assemble-series.exs) builds series `3001866d240c…` in `results-page/results/`. It hands the exporter the full run with the rerun's beacon-pr-687 attempt in place of the errored one. It then adds an `assembled` entry to the setup and names the run `flash-next-v6-assembled-1`. It is not the record of one run.

| Assembled run | 19 cases | beacon-pr-687 | Passed |
| --- | --- | --- | ---: |
| `flash-next-v6-assembled-1` | full run `20261118-115818-69764904` | rerun `20261118-184224-6d451a46`: 172 calls, 121,154 output tokens, peak context 199,379 | 18 of 20 |

Read at context sizes ([how this works](../../docs/context-size-scoring.md)) it solves 6, 11, 13, 16 and 18 cases inside 65,536, 98,304, 131,072, 196,608 and 262,144 tokens, and 18 as run.

What separates it from a run made in one go:

- **The beacon-pr-687 attempt is a second one.** The first ended in the harness error above, without an outcome; the second is the only one graded. Its time, calls and tokens are the rerun's. The errored attempt's (102 calls, 89,578 output tokens, 1,316 seconds) count nowhere, so the run's 6.93 hours are those of the 19 cases plus the rerun.
- **The code version.** It is published as the rerun's, the last one the run ran under, as a resumed run does.
- **The series it is.** Its setup carries an `assembled` entry, so a real run never joins it. The dashboard's **Contribute a run** offers seed 102 for it, but such a run is refused at the start, since its setup lacks that entry. Runs of this model with seeds 101, 102 and 103 form the real series. Once that exists, remove this file and its sentence in the v6 release note.

Neither run recorded memory samples, so the series shows no RAM or VRAM.

## What is kept

Both runs' full logs are saved as every published run's are ([ADR 0023](../../docs/adr/0023-keep-every-published-runs-full-logs.md)). The full run's `beacon-pr-687/` folder holds the errored attempt, with the harness error in its `grade-summary.json`. The rerun's folder holds the attempt that counts. To rebuild the series file, copy both run records out of the controller as the script's header says, delete the file and run the script.
