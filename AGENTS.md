# Repository instructions

## Branches

Work on `main`: commit there and push it. Create or use another branch only when the user explicitly asks for one. This repository keeps `main` as its single branch.

## Case curation

When adding a benchmark case, resuming an unfinished candidate, changing an existing case's source or preparation, or finishing a curation batch, follow [the case curation workflow](docs/case-curation-loop.md). Every runnable case must use a prepared branch in the user's fork. The workflow defines isolation, qualification, solver validation, explicit user overrides and restoration. For screening and preservation-check design, or unexpected qualification/model results, consult [curation diagnostics and lessons](docs/curation-lessons.md).

## Run logs

Every run on the results page keeps its full logs in `verification/runs/run-<id>/` ([ADR 0023](docs/adr/0023-keep-every-published-runs-full-logs.md)). **Add to results page** writes that folder; a run published another way gets it from `Eab.RunLogs.save!/1`. Commit the folder with the run's result file. This repository is public: search a new folder for names, addresses, host names and keys before committing it. A run made by a controller on another machine arrives as files; follow [Run series and contributions](docs/runbook.md#run-series-and-contributions).

## Shared machine constraint

This machine is used concurrently for other work. Functional benchmarks, model accuracy/task-success evaluations, fixture qualification, builds and correctness/concurrency tests are allowed here when speed is not the subject. Run those locally when needed; do not ask for another host merely because the project calls them benchmarks.

This machine runs the benchmark controller. It may record elapsed attempt time for runs whose model is served on another machine, with parallel attempts at 1: the model server and network dominate those times. Never time a model served on this machine, and never run speed-based benchmarks, throughput/latency measurements or performance comparisons of this machine itself. Do not run combined evidence scripts that include such measurements. Disable automatic elapsed-time measurement before local solver validation as described in the curation workflow.

Use bounded resource concurrency for local functional work. Watchdog timeouts may detect hangs; do not interpret their elapsed times or routine test/build durations as performance evidence. Historical timings from this machine are unsuitable indicators for performance decisions. Speed/performance qualification requires a separate suitable environment and explicit authorization to use it.

On 2026-10-08 the user ordered all Bream speed-test evidence removed and redone. Do not restore historical timing results or derived performance claims. Keep correctness evidence and source; new speed qualification requires another suitable environment and explicit authorization.
