# Measure speed on fixed speed cases and publish each run's machine

Once results are published, people will say a model runs twice as fast with other server flags, another quantization or other hardware. The user wants to try such claims on a few cases and publish only how fast they ran, so visitors can find a model's speed on hardware like their own. A full run per claim is too long, and a series' score has nothing to gain from it.

How fast a model generates depends on how long its conversations get. In the Qwen3.8-27B UD-Q6_K_L run, the whole run averaged 37.9 generated tokens per second, but its five fastest cases averaged 50.0 with nothing changed. A speed claim on a few cases is therefore only comparable with measurements on the same cases.

**Speed cases:** `config/speed-cases.json` names five current cases for the benchmark: plausible-pr-6449, livebook-pr-2219, livebook-pr-3076, accent-pr-183 and operately-pr-1069. They range from short to long conversations across four projects and are usually solved, so they time ordinary agent work. They take about 2.3 hours for the Q6_K_L above. They live outside `config/benchmark.json`, because that file is part of the frozen release, and changing it would stop earlier runs from being resumed or repeated.

**Speed runs:** a run started with **Speed run** works on the speed cases only, one at a time, on a model served by llama.cpp or Strata. It is never scored and joins no run series, so any quantization or machine of a model can be measured. Publishing it writes one file, `speed/<run-id>.json`, holding the model, settings, the run with its case outcomes and times, and its machine. Its `series_id` names the series its setup belongs to, whether or not that series is published. A full run timed on all speed cases is a speed measurement too, with no extra work.

**Machine:** every published run now states where its model was served. That means its GPUs with their memory, CPU, system RAM, the server and its build, the KV cache type, and the server's speed-related flags. The memory collector already read all of these on the model host. Only flags on an allowlist are published, under their long names, because the command line also holds paths, the host, the port and the API key file. A draft model's path is reduced to its file name. Strata reports no command line. The machine is not part of a series' identity, so runs of one series may come from different machines, and each run shows its own.

Public schema 10 adds each run's `machine`; series published earlier keep their files and are upgraded when they take another run. The results page shows each run as one block: its outcome, machine, server, flags, speed, time and memory peak together. A series' details list the speed of that exact setup on the speed cases, on every machine and server configuration measured; another quantization is another setup and does not appear there. A **Speed by machine** list shows every measurement, so quantizations of one model compare side by side, filtered by GPUs and by the family buttons. Nothing about speed is scored or charted.

## Consequences

- Visitors can compare one model's quantizations and machines on identical work. Pass counts on five cases show whether a setup still solves them, which matters for changes that alter answers, such as KV cache precision.
- System RAM comes from the memory samples the collector already sends, so it needs no collector reinstall. Runs recorded before this change have no RAM in their run record; the two published v6 runs had theirs read from their first sample.
- Machines differ in what limits speed beyond what is recorded, such as GPU power limits, PCIe links and memory speed. Reading those needs a collector change on every model host.
- Changing the speed cases makes earlier speed runs incomparable. Speed cases belong to one benchmark release and change with it.

## Considered options

- **Let each speed run pick its cases:** shorter cases look faster with no change at all, so claims could not be compared or checked.
- **Attach speed runs to a published series:** a quantization without a full run could not be measured, and the point is to compare quantizations and machines of one model.
- **Put the speed cases in `config/benchmark.json`:** simpler, but it changes the frozen release.
- **Publish the whole server command line:** complete, but it exposes paths and credentials' file locations; an allowlist names exactly what affects speed.
