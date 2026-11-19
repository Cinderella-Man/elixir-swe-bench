# The first v6 results, archived on 2026-11-19

On 2026-11-19 the case images were given Python and the other programs agents reach for ([ADR 0024](../../docs/adr/0024-give-case-images-the-programs-agents-reach-for.md)). Every v6 result made before that came from images without them. The user decided to archive those results and start `elixir-agent-benchmark-v6` from scratch on the new images.

Nothing was deleted. The files were moved here unchanged.

## What is here

- **[`results/`](results/):** the eleven series files, as they were in `results-page/results/`.
- **[`runs/`](runs/):** the full logs of the nine local-model runs, as they were in `verification/runs/`. Each folder's `manifest.json` still matches its files.

The logs of the Claude Code runs were saved by hand before run logs had a common place, and stay where they were: [Opus 5.5](../opus-validation-2026-11-17/README.md), [Sonnet 5.5](../sonnet-series-2026-11-17/README.md) and [Haiku 5.5](../haiku-series-2026-11-17/README.md). So do the records of how some series were put together: [the local series](../local-series-2026-11-18/README.md) and [Qwen3.8 Flash Next](../flash-next-series-2026-11-18/README.md).

## The archived series

"Passed" is cases passed of 20 in each run of the series.

| Series file | Model | Harness | Thinking | Runs | Passed | Logs |
|---|---|---|---|---|---|---|
| `f3c7588f601f…` | Opus 5.5 | Claude Code | xhigh | 2, assembled | 20, 19 | [opus-validation-2026-11-17](../opus-validation-2026-11-17/) and v5's [opus-validation-2026-10-26](../opus-validation-2026-10-26/) |
| `b6f2e9a0c441…` | Sonnet 5.5 | Claude Code | max | 2, assembled | 20, 20 | [sonnet-series-2026-11-17](../sonnet-series-2026-11-17/) and v5's [sonnet-series-2026-10-28](../sonnet-series-2026-10-28/) |
| `3ed14e38d46b…` | Haiku 5.5 | Claude Code | max | 2 | 19, 19 | [haiku-series-2026-11-17](../haiku-series-2026-11-17/) |
| `9d24395df9ff…` | Qwen3.8-27B UD-Q4_K_XL | Pi | xhigh | 1 | 18 | [`run-20261117-072245-3bd94d5c`](runs/run-20261117-072245-3bd94d5c/) |
| `3001866d240c…` | Qwen3.8-Flash-Next UD-IQ2_XS | Pi | xhigh | 1, assembled | 18 | [`run-20261118-115818-69764904`](runs/run-20261118-115818-69764904/) and the one-case rerun [`run-20261118-184224-6d451a46`](runs/run-20261118-184224-6d451a46/) |
| `75a9990dffea…` | DeepSeek-V4.1-Flash-1017 UD-IQ1_M | Pi | high | 1 | 17 | [`run-20261113-193538-5205670a`](runs/run-20261113-193538-5205670a/) |
| `c09888fcf437…` | Qwen3.8-27B UD-Q6_K_L | Pi | xhigh | 1 | 16 | [`run-20261116-113511-21de1916`](runs/run-20261116-113511-21de1916/) |
| `e064391beb99…` | Qwen3.8-27B Q8_0 | Pi | xhigh | 1 | 16 | [`run-20261118-211234-9347bf7b`](runs/run-20261118-211234-9347bf7b/) |
| `236af9a397a6…` | DeepSeek-V4.1-Flash-1017-GSQ-RCO-Coder IQ2_XXS | Pi | high | 1 | 15 | [`run-20261114-085614-515bd299`](runs/run-20261114-085614-515bd299/) |
| `48623336474f…` | Flint Q8_0 | Pi | on | 1 | 11 | [`run-20261117-232211-330ad401`](runs/run-20261117-232211-330ad401/) |
| `35a68e66c738…` | Flint UD-Q4_K_XL | Pi | on | 1 | 10 | [`run-20261118-072542-6db9af55`](runs/run-20261118-072542-6db9af55/) |

## Why they are off the results page

The page keeps an earlier release in `results-page/releases/<name>/`, and tells releases apart by their benchmark ID. These series carry the ID that v6 keeps, so they cannot stand beside the new v6 results as a release of their own without their files being edited. They are kept as files instead.

They should not be compared with new v6 results. The cases, tickets, grader and limits are the same; the containers are not. Agents ran a program these images lacked in two thirds of the attempts ([research note](../../docs/research/agent-environment-gaps-2026-11-19/README.md)).

## What else changed with the archive

- **`results-page/results/` is empty,** so v6 shows no results until its first new run is added. v5 stays the page's primary release.
- **The v6 note in `results-page/releases.json`** no longer describes the assembled Opus and Sonnet series, which are here now.
- **`verification/runs/` is empty** and takes the logs of new runs as before.
- **Paths written before the move** in [the local series record](../local-series-2026-11-18/README.md) and the two research notes of 2026-11-19 were changed to point here. Other dated records keep their wording; where they say `results-page/results/` or `verification/runs/`, read this folder.

## The controllers' own run data

A controller groups the runs in its data folder into series by their setup, and a seed that is already filled is not filled again. Old v6 runs left there would stand in for the new ones. They were moved inside the data folder, from `runs/` to `archive/v6-2026-11-19/runs/`, where the controller no longer lists them and nothing is lost. Runs of other releases stay.

With the controller idle:

```bash
docker compose exec -T benchmark bin/eab rpc '
  dest = Eab.Store.path("archive/v6-2026-11-19/runs")
  File.mkdir_p!(dest)
  for run <- Eab.Store.runs(), get_in(run, ["protocol", "inventory", "id"]) == "elixir-agent-benchmark-v6" do
    File.rename!(Eab.Store.path("runs/#{run["id"]}"), Path.join(dest, run["id"]))
    IO.puts("archived #{run["id"]}")
  end'
docker compose restart benchmark
```

The restart makes the controller read its run list again. On this repository's main controller that moved 20 runs on 2026-11-19: the published full runs, the single-case attempts and escape tests, and one full run that had ended in an error that morning. Its 37 v5 runs stayed, and it lists no v6 series. A second controller that holds v6 runs needs the same two commands before its first new run.
