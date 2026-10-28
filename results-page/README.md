# Elixir SWE Bench results page

A static, shareable page for Elixir SWE Bench results, produced by this repository's benchmark runner. One dot represents a run series ([ADR 0011](../docs/adr/0011-publish-three-run-series.md)): up to three runs of one model through one harness on the current admitted cases. The dot sits at the mean score; a band shows ±1.96 standard errors of rerun noise once two runs exist. Hollow dots are provisional series that still miss runs. No server, database, npm packages or external assets are needed to serve it.

The page contains a title, maximum model-size slider and one shared chart, with labels immediately left of their dots. Case outcomes and recorded settings open below the chart. There is no comparison selector or model search.

The benchmark run history and published results were cleared on 2026-10-20 because their thinking presets were not reliably recorded, and again on 2026-10-26 because the cases are being rebuilt ([ADR 0012](../docs/adr/0012-rebuild-release-and-validate-with-unpublished-opus-runs.md)). Every series starts on the rebuilt release. With no published records, the page shows “No benchmark results yet” and hides the slider and chart guidance.

Each point names its model, its quantization when it has one, and its thinking level: Extra for `xhigh`, Max for `max`, and so on, as in "Opus 5.5 Extra". Its harness and version, run count, settings and memory are in its details, opened by clicking the point. Comparisons across harnesses confound the model with the harness. Opus 5.5 validated the cases through Claude Code, which favours it slightly. Its validation runs stay unpublished, except its last two: their outcomes could not change the release, so they count as the first two runs of its series ([ADR 0012](../docs/adr/0012-rebuild-release-and-validate-with-unpublished-opus-runs.md)).

Fresh runs on configured ratx570 endpoint hostnames collect model-service RAM and VRAM throughout the run. Their exported summaries include sampled peaks, the highest simultaneous RAM + VRAM total, per-GPU allocations, configured context, runtime and collection coverage. Model weight size remains a separate field. The dashboard shows collection configuration before starting a run; a local result's details say when no memory observations were saved.

The slider still filters model weight-file size in decimal GB when results exist. Changing it to “Max VRAM+RAM used” is deferred until fresh runs provide the required memory data. Observed VRAM/RAM does not yet determine eligibility for this filter. A numeric limit hides unknown-size/API models; All restores them.

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

## Adding a result

In the benchmark dashboard, select a completed full run and click **Add to results page**, beside **Download report**. It adds the run to its series, creating the series file if this is its first run, and rebuilds the page. The series file keeps the saved model identity, harness, settings, the required setup for missing runs, and per run its seed, outcomes, token usage, code version, server build and available memory measurements. **View results** opens the built-in preview at `/results/`; the standalone preview on port 4173 reads the same files. Repeated clicks keep the existing public record.

A run joins the series whose setup it matches: cases and fixture files, harness and version, model artifact and quantization, server type, chat template, server sampling defaults and effective settings apart from seed. Local series take one run each for seeds 101, 102 and 103; adding a second run for a filled seed, or a fourth run, is refused. Subscription series take their first three runs. Validation runs are refused. To fill a provisional series from the dashboard, use **Contribute a run** under **Run series**: it fills the settings and a missing seed, and the run only starts if the connected endpoint matches the published setup.

Docker Compose mounts this checkout's `results-page/` into the benchmark container. The button writes one public JSON file per series into `results-page/results/<series-id>.json`, and generated files into `results-page/dist/`. Outputs remain editable by the checkout owner. It does not commit or push: commit the changed series file and push to `main` to update GitHub Pages.

For optional label/size overrides or an exported run from another installation, the command line remains available:

```sh
mix eab.results add /path/to/run.json \
  --model-label 'My model 32B' \
  --quantization 'Q4_K_M' \
  --size-gb 20.5 \
  --resources /path/to/memory-observation.json \
  --evidence-url 'https://example.com/public-run-evidence'
```

All flags are optional. Model name, quantization and size use saved artifact metadata when available, including legacy runs whose routing aliases differ from their artifact names. If the server omits size, a configured collector can supply the installed GGUF file sizes, including all numbered shards; exports label this source `artifact_files`. `--quantization` and `--size-gb` mark owner-supplied values; absent metadata stays unknown. `--note` adds context shown in the details. The command uses the same publisher as the dashboard button. Adding an existing run rebuilds the preview and preserves its public JSON, including manual edits; edit that JSON deliberately to correct a label or note.

To use the command line with a run stored in Docker, copy the original run file out to an ignored local directory first:

```sh
mkdir -p .local/publication
docker compose cp benchmark:/data/runs/RUN_ID/run.json .local/publication/run.json
mix eab.results add .local/publication/run.json
```

The exporter requires a completed full-inventory source run and a pass/fail grade for every case. Errors, interruptions, partial repeats, validation runs and unknown settings are rejected; a Claude Code run also needs its recorded Claude Code version. Every current case must occur in the run with matching fixture hashes. It exports only those current cases and leaves the original run unchanged. Endpoint URLs, model file paths, account identifiers, transcripts and raw provider metadata are excluded. It uses the recorded grades, not a new audit of the underlying grading receipts. Review the model label, optional note and evidence link before publishing; they are taken from the run that creates the series.

Commit the new or changed file in `results-page/results/` and push it to `main`. After the one-time Pages setup below, GitHub rebuilds and publishes automatically. No manifest or HTML edits are needed. The exporter creates the public schema (version 5); `check` and `build` validate all records and compute each series' mean, interval, per-case pass counts, missing seeds and highest memory peak.

```sh
mix eab.results check
mix test test/eab/results_test.exs --max-cases 2
```

The builder checks every public record against `config/benchmark.json` and the current case fixture hashes. A changed inventory or fixture makes stale series fail validation: start new series on the new release. Benchmark code changes alone never force a rerun. Do not splice attempts from different runs together. Unknown future settings fail validation; extend the public schema when that happens.

## Capture memory and future timings

Fresh runs collect memory automatically. For a separate loaded-model snapshot, the [Elixir collector](../tools/memory_collector/README.md) reads the selected inference process with `nvidia-smi` and Linux procfs/cgroup counters, plus authenticated model properties. It performs no inference and no speed measurement. Run the installed release **on the model host**, replacing the example engine PID, model port and existing API key-file path:

```sh
/srv/elixir-agent-benchmark/memory-collector/bin/eab_memory_collector \
  eval 'Eab.MemoryCollector.CLI.main()' > memory-observation.json <<'JSON'
{"mode":"snapshot","pid":1234,"port":8414,"key_file":"/path/to/existing-api-key"}
JSON
```

The key, host address, PID, absolute artifact path and GPU UUIDs are not exported. GPU usage is attributed by process PID and physical GPU UUID before producing public values; whole-host GPU/RAM figures can include unrelated work. On the inspected Strata deployment, its own hardware panel selected the wrong physical GPUs, so it was not used for memory attribution. The exporter accepts a snapshot only when artifact, backend and context match the result. A matching artifact name is not a checksum/provenance guarantee.

Pi attempts save monotonic elapsed milliseconds in `measurement.attempt_ms` in the private run record, from Pi startup through completion. Claude Code attempts store no timing. Public schema version 5 publishes no timing: a series combines runs from different machines and days, and this project does not score speed. Functional tests use synthetic clocks. Input/context size is not a generated-token count. Runs on configured model hosts continue collecting memory independently; a series shows the run with the highest simultaneous RAM + VRAM peak.

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
- `results/*.json`: one public record per run series, named by its series ID; these are the everyday additions.
- `lib/eab/results.ex` and `lib/eab/results/`: public export, validation and static site generation.
- `mix eab.results`: add, check, build and preview commands using Elixir 1.19+ and OTP 28+.
- `lib/eab/series.ex`: series membership, seeds, mean score, interval and peak memory.
- `test/eab/results_test.exs` and `test/eab/series_test.exs`: ExUnit checks for eligibility, current-case projection, model metadata, GPU attribution, series membership and public exports.
- `dist/`: generated HTML, assets and downloadable result data; deployed by GitHub Actions.

### Automatic memory from benchmark runs

The benchmark now streams model-service memory from a configured model host during each ordinary run; see [runner setup](../README.md#run-memory-on-the-model-host). `mix eab.results add path/to/run.json` automatically includes its saved `memory` summary. No separate `--resources` option is needed for these runs.

`resources.kind = "run_samples"` records sampled run peaks for VRAM, service RAM, RSS and simultaneous RAM + VRAM, plus per-GPU peaks, configured context, runtime, KV cache, interval, sample count and complete/partial coverage. The exporter strips private host/service identifiers and GPU UUIDs. It refuses to combine resumed sessions from different deployments or physical GPUs. The page distinguishes run samples from the earlier `loaded_snapshot`; the old results are not backfilled with new measurements. Model weight size remains a separate field and slider.

Case additions and source migrations follow [prepared fork sources](../docs/prepared-fork-sources.md). Published results retain their frozen release identities; changing a case to a prepared fork does not relabel historical attempts. Single-case curation runs are not a full-inventory score. See the [source audit](../verification/prepared-forks-2026-10-20/README.md).
