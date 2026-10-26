# Publish three-run series and keep runs valid across code changes

Repeated runs of one model with identical settings and seed give different case outcomes: sampling, GPU batching and the agent's own unseeded test output all vary, and subscription APIs offer no seed ([research](../research/run-to-run-variance-2026-10-26.md)). A published result is therefore a run series: three ordinary runs of one model artifact and quantization through one harness on one benchmark release, using seeds 101, 102 and 103 where the endpoint supports seeds. Its score is the mean of its runs' scores. Its ± covers rerun noise on the frozen cases only, computed from per-case pass counts as the Terminal-Bench leaderboard does, `sqrt(Σ pᵢ(1−pᵢ)/(k−1)) / n` shown as ±1.96·SE once two runs exist. Every series on a release gets the same number of runs; a much larger release may lower it. This amends [ADR 0003](0003-single-model-website.md) and replaces the rule that a published result is one run.

Anyone may add a run to a series. A run joins when its cases and fixture files, harness and harness kit (for Claude Code, the installed kit files and frozen prompt), model artifact and quantization, server type, chat template, server sampling defaults, thinking effort, context size, generation budget and per-response cap match. Hardware, endpoint, model file path, server build, slot count, benchmark code version and the Claude Code program version may differ and are recorded per run; the desktop app updates Claude Code on its own, like a llama.cpp server build. Each seed counts once: the first run with a final score fills it, and errored or cancelled runs leave it open; subscription series take their first three runs with final scores. Unfinished series are published as provisional points that state how many of the three runs they have, name their missing seeds and list the required setup. The dashboard refuses to start a contributed run whose endpoint does not match that setup.

Benchmark code changes never force a rerun. Only a change to the case set or a case's fixture files makes published series stale, so case changes are batched into planned releases and the case set stays frozen in between. Resuming an interrupted run likewise requires matching cases, harness, model and settings but not matching benchmark code, as error retries already do; this amends [ADR 0008](0008-resume-completed-case-checkpoints.md). The accepted risk is a grader or preparation change landing between runs of one series.

## Considered options

- **One run per point with a case-sampling interval**: no extra runs, but a standard error of 11–13 points at 14 cases, and outcome flips between reruns stay invisible.
- **Several attempts per case inside one run**: the same statistics, but it changes the run, resume and comparison model, and the attempts cannot be spread across days, machines and contributors.
- **Best of three or all of three as the headline**: best of three reintroduces best-of selection and overstates single-attempt success; all of three measures consistency, not expected success.
- **Deterministic serving**: impossible for subscription models, and locally still one draw per case.
- **Five or more runs, as Terminal-Bench requires**: tighter intervals at five-thirds the cost. Three matches Artificial Analysis.
- **One release ID per series**: the release ID hashes benchmark code, so every commit would split a series.

## Consequences

- Runs made before [ADR 0012](0012-rebuild-release-and-validate-with-unpublished-opus-runs.md) were deleted; every series starts on the rebuilt release.
- A point's memory position is the highest RAM + VRAM peak across its runs.
- Dashboard comparison, publication and the results page must accept runs of one series that differ in seed.
- Deferred: trust checks for contributed runs, the RAM + VRAM filter, and incremental top-ups when cases change.
