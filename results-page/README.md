# Elixir SWE Bench results page

A static, shareable page for Elixir SWE Bench results, produced by this repository's benchmark runner. One dot represents a run series ([ADR 0011](../docs/adr/0011-publish-three-run-series.md)): up to three runs of one model through one harness on the current admitted cases. The dot sits at the mean score, up the side, and at the run series' peak VRAM + RAM, along the bottom; a vertical band shows ±1.96 standard errors of rerun noise once two runs exist. Hollow dots are provisional series that still miss runs. No server, database, npm packages or external assets are needed to serve it.

A release whose series recorded their attempts' peak context has another chart, described under [Cases against context](#cases-against-context); what follows describes the chart of a release without that record, such as v5.

The page contains a title and one shared chart: cases passed against the peak VRAM + RAM the model server used in our runs, on a linear scale with a tick every 64 GB. Hosted APIs and series without a memory measurement sit in a strip of their own at the right, on the same score scale. A dashed line steps through the series that pass more cases than every series using less memory. Series are grouped into model families: a family is the model's name without a quantizer's mark (`-GSQ-RCO`, `-Gyro-L`), or `model.family` when a record carries one. A Coder variant is another model and keeps its own family, so `...-GSQ-RCO-Coder` belongs to `...-Coder`. Five colours, which pass the dataviz validator's pairwise checks on white, go in a fixed order to the families with more than one series, best family first; every other family is grey. Colours are set once from all results, so highlighting never repaints a family. A line in the family's colour joins its quants in memory order. Pi dots are circles and Claude Code dots diamonds. The family buttons above the chart are its colour legend and its filter: choosing families fades the others, and Show all restores them. Each family's best series (most cases, then least memory) is named first, with the family and its quantization; the selected series, then the frontier, then the family's other quants, named by quantization and thinking level, take the room left. A family with no room is shown by its number, named in a key below the chart; another quant with no room is left to the tooltip and the table. Series at the same score and nearly the same memory are spread a few pixels apart. Hovering or focusing a dot shows its result, memory, harness and runs; a sortable table view lists the same for every series. Case outcomes, each run's machine and speed, and recorded settings open below the chart. Below the table view, **Speed by machine** lists how fast every model ran on the speed cases, on every machine measured, filtered by GPUs and by the family buttons. There is no model search.

The benchmark run history and published results were cleared on 2026-10-20 because their thinking presets were not reliably recorded, and again on 2026-10-26 because the cases are being rebuilt ([ADR 0012](../docs/adr/0012-rebuild-release-and-validate-with-unpublished-opus-runs.md)). Every series starts on the rebuilt release. With no published records, a release shows “No benchmark results yet” and hides the chart guidance.

## Releases

The page can hold more than one benchmark release and shows one at a time. A **Release** row under the title switches between them; `?release=v6` opens one directly, and series of different releases never share a chart.

- **`results/`** holds the series of the current release, the one `config/benchmark.json` names. The dashboard's **Add to results page** and `mix eab.results add` write here, and these series are checked against the current case files. The dashboard button also saves the run's full logs to `verification/runs/run-<id>/` ([ADR 0023](../docs/adr/0023-keep-every-published-runs-full-logs.md)); push that folder with the series file.
- **`releases/<name>/`** holds the series of an earlier release, kept exactly as they were published. Their cases have changed since, so they are checked against each other (one benchmark ID, one case list, one set of case files) and never against the current cases. They take no more runs.
- **[`releases.json`](releases.json)** names the release the page opens on (`primary`, a benchmark ID) and gives each release a one-line note shown beside the switch. Without it the current release is primary.

On 2026-11-13 two cases changed, local attempts lost their generation budget and stray edits stopped failing submissions ([ADR 0016](../docs/adr/0016-limit-local-attempts-by-the-context-window-only.md), [ADR 0017](../docs/adr/0017-discard-changes-outside-the-edit-area.md)). That made benchmark `elixir-agent-benchmark-v6`. The twelve series of `elixir-agent-benchmark-v5` moved to [`releases/v5/`](releases/v5/) and stay the page's primary release while v6 collects runs. When v6 has enough series, change `primary` in `releases.json` to `elixir-agent-benchmark-v6`; v5 then stays reachable through the switch.

To retire the current release later, move its files from `results/` into a new `releases/<name>/` folder in the same commit that changes the cases or `config/benchmark.json`. Releases are told apart by their benchmark ID, so that only works when the next release takes a new ID. When v6 was started again under the same ID, its earlier series could not stay on the page and went to [`verification/v6-archive-2026-11-19/`](../verification/v6-archive-2026-11-19/README.md).

A series' name is its model, its quantization when it has one, and its thinking level: Extra for `xhigh`, Max for `max`, and so on, as in "Opus 5.5 Extra". Its harness and version, run count, settings and memory are in its details, opened by clicking the point. In the details, an "over 262k" tag marks a case, and a run, where the model generated more than the declared 262,144-token budget; Claude Code cannot enforce that budget, so the attempt is flagged, not failed. A grey tag marks a case cut off by a budget before the agent had finished: "stopped at 65k" when a generation budget ran out (local series have had none since ADR 0016, and show "Generation budget / case: No cap"), "context full" when the conversation filled the context limit, and "reply cut at 8k" when one reply reached the 8,192-token per-reply limit mid-answer. Only series made before [ADR 0015](../docs/adr/0015-drop-the-per-reply-token-cap.md) have that limit; later local series show "Tokens / response: No cap". The patch at that point was graded, so a cut-off case can still pass. In a release with token allowances ([ADR 0021](../docs/adr/0021-give-each-case-a-token-allowance.md)) it cannot: a case passes only if the agent finished on its own inside the case's allowance. The case list then shows each case's output tokens beside its allowance, the grey tag reads "stopped at allowance", and a "patch passed" tag marks a case whose patch passed every check although the attempt did not finish inside the allowance. Schema 11 records that verdict as each case's `patch_passed`, and the allowances in the series' `setup`. No release sets allowances.

## Dark and light

The page is dark by default. A button in the top corner switches to light and back, and the choice is kept in the browser. Every colour is a variable set once per theme in `styles.css`; the line and family colours are each theme's own steps of the same hues, checked against that theme's background. On the dark background only four family colours pass every pairwise check, so the second family's colour differs between the themes.

## Cases against context

Where a release has series that recorded their attempts' peak context, as v6 does, the chart is cases solved against the context the whole attempt must fit in, from 0 to 262,144 tokens ([ADR 0022](../docs/adr/0022-score-runs-at-context-sizes.md)). Memory is no longer an axis there: a model's peak VRAM + RAM is measured with the whole 262,144-token window reserved, whatever the work needed, and hosted models have none. It stays in the table view and in each series' details.

Each series is one line with a dot every 16,384 tokens, from 32,768 to 262,144: the cases the series solves when the whole attempt must fit in that much context, averaged over its runs. The five context sizes are among those readings, so a dot there shows the number the table view gives. The lines between dots only join them. The dot that ends a line at 262,144 shows the harness by its shape and is hollow while the series is provisional.

A legend above the plot names every line with its key, most cases first, and the number after a name is what the series solves inside 262,144 tokens. Pointing at a name, or near a line, lights that line and dims the rest. Pointing anywhere in the plot shows every series' count at the nearest reading, most first. A series without recorded peaks has no line and is listed last. Clicking a name or the dot at a line's end opens the series' details.

Each line has its own colour and its own dashes, both following the series in the order the series were first run, so neither changes when scores change or a series is added. Eight colours cannot all be told apart at a glance: blue and violet, aqua and green, and orange and red are near each other. The four dash styles are dealt so that no two near colours share one. A ninth series and later are grey.

Until 2026-11-18 a strip beside the plot, **As run**, held a second dot per series: its own score with no context size applied. It read as part of the context axis and confused more than it told, so it was removed. That score is the **Cases passed** column of the table view and the score in a series' details.

The table view gives the same reading as numbers. Beside **Cases passed**, each series' own score as it was run, five columns hold the cases it solves inside 65,536, 98,304, 131,072, 196,608 and 262,144 tokens of context ([ADR 0022](../docs/adr/0022-score-runs-at-context-sizes.md), [explained here](../docs/context-size-scoring.md)). At a size a case counts only if the agent finished on its own, the attempt's peak context is within the size and its patch passes, so a size is stricter than the series' own score. A series whose attempts did not all record their peak context shows a dash in those columns. A series' details list each attempt's peak context beside its case. Schema 12 records it as each case's `peak_context_tokens`; the builder adds each series' score, interval and per-case counts at every size as `by_context`.

Until 2026-11-18 a **Context size** selector above the chart switched every score on the page to one size. The lines already show every size at once, so it was removed, and an old `context=` link opens the same page.

v6 was started again on 2026-11-19, when the case containers were given Python and the other programs agents reach for ([ADR 0024](../docs/adr/0024-give-case-images-the-programs-agents-reach-for.md)). The eleven series published before that were made in containers without them and are [archived](../verification/v6-archive-2026-11-19/README.md), off this page; three of them were assembled from other runs, which the archive records. Every v6 series on the page is made of ordinary full runs on the new containers. Each case name links to its summary page in [`docs/cases/`](../docs/cases/README.md): the problem in a few sentences, the ticket the agent receives, the case files and the upstream pull request. The case list says how many attempts were cut off, and the runs table counts them per run. Comparisons across harnesses confound the model with the harness. Opus 5.5 validated the cases through Claude Code, which favours it slightly. Its validation runs stay unpublished, except its last two: their outcomes could not change the release, so they count as the first two runs of its series ([ADR 0012](../docs/adr/0012-rebuild-release-and-validate-with-unpublished-opus-runs.md)).

Fresh runs on configured model-host endpoint hostnames collect model-service RAM and VRAM throughout the run. Their exported summaries include sampled peaks, the highest simultaneous RAM + VRAM total, per-GPU allocations, configured context, runtime and collection coverage. Model weight size remains a separate field. The dashboard shows collection configuration before starting a run; a local result's details say when no memory observations were saved.

## Preview

From the repository root with Elixir 1.19+, OTP 28+ and dependencies installed (`mix deps.get`):

```sh
mix eab.results build
mix eab.results serve
```

Open [the local preview](http://127.0.0.1:4173). You can also open `results-page/dist/index.html` directly in a browser; data is loaded from a local script, so no fetch server is required. Generated `dist/` files are ignored by Git.

For a Docker-only installation, prepare the tooling image and dependencies using the [development setup](../docs/runbook.md#bounded-correctness-checks), then run:

```sh
docker run --rm --cpus=2 --network host --user "$(id -u):$(id -g)" \
  -e HEX_HOME=/tmp/hex -v "$PWD:/app" -w /app eab-tooling:dev \
  mix eab.results serve
```

Use the same container command with `mix eab.results add .local/publication/run.json`, `check` or `build` for publication work.

## Speed runs

How fast a model generates depends on how long its conversations get, so speed is compared on fixed **speed cases**: [`config/speed-cases.json`](../config/speed-cases.json) names five current cases, from short to long conversations ([ADR 0020](../docs/adr/0020-measure-speed-on-fixed-speed-cases-and-publish-each-runs-machine.md)). To measure a model on a machine, connect it in the dashboard, tick **Speed run** under the run settings and run. Only the speed cases run, one at a time; it takes a fraction of a full run and works for any quantization, published or not. When it completes, **Add speed run to results page** writes `speed/<run-id>.json` and rebuilds the page; `mix eab.results add` takes an exported speed run the same way. A speed run is never scored and joins no run series. Its `series_id` names the series its setup belongs to.

Every published run, full or speed, states its `machine`: the model host's GPUs with their memory, CPU, system RAM, the server and its build, the KV cache type and the server's speed-related `flags`. Only allowlisted llama.cpp flags are published, under their long names; paths, host, port and key files are not, and a draft model's path becomes its file name. Strata reports no command line. The page shows each run as one block with its outcome, machine, server, flags, speed, time and memory peak. A series' details list the speed of that exact setup on the speed cases, on every machine and server configuration measured, with full runs counting their times on those cases. Quantizations and settings of one model are compared in **Speed by machine**. System RAM is read from the memory samples. Runs recorded before 2026-11-17 kept no RAM in their run record; the two published v6 runs had theirs read from their first sample.

Speed runs belong to one release. When the cases change, move `speed/` into `releases/<name>/speed/` with that release's series and name new speed cases for the new benchmark.

## Adding a result

In the benchmark dashboard, select a completed full run and click **Add to results page**, beside **Download report**. It adds the run to its series, creating the series file if this is its first run, and rebuilds the page. The series file keeps the saved model identity, harness, settings, the required setup for missing runs, and per run its seed, outcomes, token usage, case times and model speed, the machine its model was served on, code version, server build and available memory measurements. **View results** opens the built-in preview at `/results/`; the standalone preview on port 4173 reads the same files. Repeated clicks keep the existing public record.

A run joins the series whose setup it matches: cases and fixture files, harness and version, model artifact and quantization, the served files' sha256 when they were hashed, server type, chat template, server sampling defaults and effective settings apart from seed. Local series take one run each for seeds 101, 102 and 103; adding a second run for a filled seed, or a fourth run, is refused. Subscription series take their first three runs. Validation runs are refused. To fill a provisional series from the dashboard, use **Contribute a run** under **Run series**: it fills the settings and a missing seed, and the run only starts if the connected endpoint matches the published setup.

Docker Compose mounts this checkout's `results-page/` into the benchmark container. The button writes one public JSON file per series into `results-page/results/<series-id>.json`, and generated files into `results-page/dist/`. Outputs remain editable by the checkout owner. It does not commit or push: commit the changed series file and push to `main` to update GitHub Pages.

For optional label/size overrides or an exported run from another installation, the command line remains available:

```sh
mix eab.results add /path/to/run.json \
  --model-label 'My model 32B' \
  --quantization 'Q4_K_M' \
  --quantized-by 'ukisai' \
  --size-gb 20.5 \
  --resources /path/to/memory-observation.json \
  --evidence-url 'https://example.com/public-run-evidence' \
  --source-url 'https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/blob/main/Qwen3.8-27B-UD-Q6_K_L.gguf' \
  --release-label 'v3.1'
```

All flags are optional. Model name, quantization and size use saved artifact metadata when available, including legacy runs whose routing aliases differ from their artifact names. If the server omits size, a configured collector can supply the installed GGUF file sizes, including all numbered shards; exports label this source `artifact_files`. When Strata reports only its pack folder, the model name and quantization also come from those files, with quantization source `artifact_files`; the series setup keeps the server's model alias. `--quantization` and `--size-gb` mark owner-supplied values; absent metadata stays unknown.

Every series also records who made its quantization, `quantized_by`, because the same model name can come from several makers. A configured collector reads it from the served file's GGUF header (`general.quantized_by`, as Unsloth, ISTA DASLab and Agention write it), source `artifact_files`; that maker is part of the series setup, so identically named files from different makers stay separate series, and a contribution started before the collector has read it is checked again when it is exported. A file that names no one, such as ukisai's Swift GGUFs, takes `--quantized-by`, source `owner_supplied`: it is shown, but it is not part of the setup, and it is refused when the file names someone else. Otherwise the source is `not_reported`. The chart puts the maker before the quantization, as in "Unsloth UD-Q5_K_XL"; within a family, each maker's quants have a line of their own. The seven local series published before 2026-11-09 had their makers read from the archived files they were served from.

Since schema 8 every series also says which file it ran ([ADR 0018](../docs/adr/0018-declare-and-hash-model-sources.md)), because makers re-upload files under the same name. `model.source` is the model file's URL as the operator declared it before the run: host, Hugging Face `author`, `repository`, `revision`, `path` and `file`, an optional `release_label` such as `v3.1`, and `declared_by` (`operator`, or `publisher` for `--source-url`). `model.weight_files` lists each served file with the sha256 a configured collector measured on the model host; those hashes are part of the series setup (`setup.model.sha256`), so a re-upload is another series. Publication compares them with the source on Hugging Face and, when the declared revision has moved on, searches the repository's history for that upload: `verification` is `verified`, with `commit` and `commit_date` naming the upload, `differs`, or `not_checked`. `model.gguf` holds the file header's release, provenance and calibration keys, such as `general.version` and `quantize.imatrix.dataset`. Each field is null when unknown. The chart adds the release label after the quantization ("Unsloth UD-Q6_K_L v3.1"); the details link the file at its upload commit and list its hashes. Series published before 2026-11-16 have none of these and keep their IDs. A run started for one of them still joins it; once its record lists files, a run of other files is refused. `--source-url` and `--release-label` name the source of a run that declared none. `--note` adds context shown in the details. The command uses the same publisher as the dashboard button. Adding an existing run rebuilds the preview and preserves its public JSON, including manual edits; edit that JSON deliberately to correct a label or note.

To use the command line with a run stored in Docker, copy the original run file out to an ignored local directory first:

```sh
mkdir -p .local/publication
docker compose cp benchmark:/data/runs/RUN_ID/run.json .local/publication/run.json
mix eab.results add .local/publication/run.json
```

The exporter requires a completed full-inventory source run and a pass/fail grade for every case. Errors, interruptions, partial repeats, validation runs and unknown settings are rejected; a Claude Code run also needs its recorded Claude Code version. Every current case must occur in the run with matching fixture hashes. It exports only those current cases and leaves the original run unchanged. Endpoint URLs, model file paths, account identifiers, transcripts and raw provider metadata are excluded. It uses the recorded grades, not a new audit of the underlying grading receipts. Review the model label, optional note and evidence link before publishing; they are taken from the run that creates the series.

Commit the new or changed file in `results-page/results/` and push it to `main`. After the one-time Pages setup below, GitHub rebuilds and publishes automatically. No manifest or HTML edits are needed. The exporter creates the public schema (version 12, which added each case's `peak_context_tokens`; version 11 added each case's `patch_passed`; version 10 added each run's `machine`; version 9 added each run's and case's `timing`; version 8 added the model's `source`, `weight_files` and `gguf`; version 7 added each case's `cutoff`: `generation_budget`, `context_budget`, `response_budget` or null). Series published as version 8 to 11 keep their files and are upgraded when they take another run; `check` and `build` validate all records and compute each series' mean, interval, per-case pass counts, missing seeds and highest memory peak.

```sh
mix eab.results check
mix test test/eab/results_test.exs --max-cases 2
```

The builder checks every record in `results/` against `config/benchmark.json` and the current case fixture hashes. A changed inventory or fixture makes those series fail validation: move them to `releases/<name>/` as an earlier release (see [Releases](#releases)) and start new series on the new one. Benchmark code changes alone never force a rerun. Do not splice attempts from different runs together. Unknown future settings fail validation; extend the public schema when that happens.

## Capture memory and future timings

Fresh runs collect memory automatically. For a separate loaded-model snapshot, the [Elixir collector](../tools/memory_collector/README.md) reads the selected inference process with `nvidia-smi` and Linux procfs/cgroup counters, plus authenticated model properties. It performs no inference and no speed measurement. Run the installed release **on the model host**, replacing the example engine PID, model port and existing API key-file path:

```sh
/srv/elixir-agent-benchmark/memory-collector/bin/eab_memory_collector \
  eval 'Eab.MemoryCollector.CLI.main()' > memory-observation.json <<'JSON'
{"mode":"snapshot","pid":1234,"port":8414,"key_file":"/path/to/existing-api-key"}
JSON
```

The key, host address, PID, absolute artifact path and GPU UUIDs are not exported. GPU usage is attributed by process PID and physical GPU UUID before producing public values; whole-host GPU/RAM figures can include unrelated work. On the inspected Strata deployment, its own hardware panel selected the wrong physical GPUs, so it was not used for memory attribution. The exporter accepts a snapshot only when artifact, backend and context match the result. A matching artifact name is not a checksum/provenance guarantee.

Pi attempts save monotonic elapsed milliseconds in `measurement.attempt_ms` in the private run record, from Pi startup through completion, with the model speed summed over their model calls. Claude Code attempts store no timing. Since schema 9 each published run carries them ([ADR 0019](../docs/adr/0019-publish-each-runs-case-times-and-model-speed.md)): every case's `timing` holds `time_ms` and `model_speed` (`source`, `calls`, `prompt_tokens`, `prompt_ms`, `generated_tokens`, `generation_ms`, `draft_tokens`, `draft_accepted`), and the run's `timing` adds up its timed cases with `measured_cases`. Timing is null when the run worked on several cases at once, for Claude Code, and in series published before schema 9. A series combines runs from different machines and days, so the page lists time and speed per run, in a **Time & speed** table and beside each case, and never averages or scores them. Functional tests use synthetic clocks. Input/context size is not a generated-token count. Runs on configured model hosts continue collecting memory independently; a series shows the run with the highest simultaneous RAM + VRAM peak.

Thinking presets appear in each chart label and detail heading, distinguishing runs of the same model with different settings. New local runs export `reasoning_effort`, `reasoning_effort_source` and `thinking_policy: server_preset`. The value can be `off`, `on` (no level), a named level including custom names, `default`, `unsupported`, or `unknown` when the host does not report it and the operator leaves it blank. Operator declarations are labeled separately from server metadata. The benchmark leaves local thinking controls to the model host. Existing records are not backfilled.

## Publish with GitHub Pages

This repository's default project-site URL will be:

**[https://cinderella-man.github.io/elixir-agent-benchmark/](https://cinderella-man.github.io/elixir-agent-benchmark/)**

The page's display name is **Elixir SWE Bench**. If you rename the GitHub repository to `elixir-swe-bench`, its default Pages address becomes `https://cinderella-man.github.io/elixir-swe-bench/`. The workflow supplies `GITHUB_REPOSITORY`, which the builder uses for page navigation links automatically. For a local preview after renaming, set `GITHUB_REPOSITORY=Cinderella-Man/elixir-swe-bench` when building. Existing frozen benchmark IDs and historical result records remain unchanged.

GitHub Pages serves HTML, CSS and JavaScript at `<owner>.github.io/<repository>/`. Public repositories can use Pages on GitHub Free. [GitHub's Pages overview](https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages)

One-time setup:

1. Commit and push the page, Elixir publication tooling and workflow changes to `main`.
2. Open the repository's [Settings → Pages](https://github.com/Cinderella-Man/elixir-agent-benchmark/settings/pages).
3. Under **Build and deployment → Source**, select **GitHub Actions**.
4. Open **Actions → Publish benchmark results → Run workflow**. Future pushes that change result files, page files or the inventory will publish automatically.

The workflow runs the publication checks, builds `results-page/dist/`, uploads only that folder, and deploys it to the `github-pages` environment. All asset paths are relative so the page works under the repository subpath. Repository source, private run files and benchmark services are not part of the deployed folder. Configure a custom domain separately if wanted later.

[GitHub's source-configuration instructions](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site) · [GitHub's custom workflow documentation](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)

## Files

- `index.html`, `styles.css`, `app.js`: page and interactions.
- `theme.js`: sets the dark or light theme before the page is drawn. It is a file of its own because the page's content policy allows no inline script.
- `results/*.json`: one public record per run series of the current release, named by its series ID; these are the everyday additions.
- `releases/<name>/*.json`: the series of an earlier release, kept as published.
- `releases.json`: the release the page opens on, and a note per release.
- `lib/eab/results.ex` and `lib/eab/results/`: public export, validation and static site generation.
- `mix eab.results`: add, check, build and preview commands using Elixir 1.19+ and OTP 28+.
- `lib/eab/series.ex`: series membership, seeds, mean score, interval and peak memory.
- `test/eab/results_test.exs` and `test/eab/series_test.exs`: ExUnit checks for eligibility, current-case projection, model metadata, GPU attribution, series membership and public exports.
- `dist/`: generated HTML, assets and downloadable result data; deployed by GitHub Actions.

### Automatic memory from benchmark runs

The benchmark now streams model-service memory from a configured model host during each ordinary run; see [runner setup](../README.md#run-memory-on-the-model-host). `mix eab.results add path/to/run.json` automatically includes its saved `memory` summary. No separate `--resources` option is needed for these runs.

`resources.kind = "run_samples"` records sampled run peaks for VRAM, service RAM, RSS and simultaneous RAM + VRAM, plus per-GPU peaks, configured context, runtime, KV cache, interval, sample count and complete/partial coverage. The exporter strips private host/service identifiers and GPU UUIDs. It refuses to combine resumed sessions from different deployments or physical GPUs. The page distinguishes run samples from the earlier `loaded_snapshot`; the old results are not backfilled with new measurements. Model weight size remains a separate field in the details; the chart places each series by the run peak.

Case additions and source migrations follow [prepared fork sources](../docs/prepared-fork-sources.md). Published results retain their frozen release identities; changing a case to a prepared fork does not relabel historical attempts. Single-case curation runs are not a full-inventory score. See the [source audit](../verification/prepared-forks-2026-10-20/README.md).
