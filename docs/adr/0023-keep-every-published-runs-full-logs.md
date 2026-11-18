# Keep every published run's full logs in the repository

A published result holds a run's outcomes and totals: pass or fail, output tokens, model calls and, since [ADR 0022](0022-score-runs-at-context-sizes.md), each attempt's peak context. Everything else about the run stayed in the data folder of the controller that made it: the agent's conversation, the controller's log, the grader's output and the patch.

Twice in two days a question could only be answered from those files. On 2026-11-17 the saved transcripts of Opus 5.5's October runs were the only record of how much context it had used per model call, which is what led to scoring by context size. On 2026-11-18 the DeepSeek series had no scores at a size, because its run had been made by a controller on another machine before peaks were recorded; its per-call token counts had to be fetched from that machine, which happened to still hold them. The Claude Code runs had their logs in the repository only because someone copied them by hand after each run.

The user asked for every model's runs to be kept the same way, without relying on anyone to remember.

**Adding a run to the results page saves its logs.** The dashboard's **Add to results page** adds the run to its series as before and then writes `verification/runs/run-<id>/`:

- **`run-summary.json`:** what was run: the release, every case file's hash, the harness, the model and its declared source, the settings and the score.
- **`calls.json`:** the prompt and output tokens of every model call of every case, in call order.
- **Per case:** the instructions the agent was given, the patch as submitted, a grade summary, the controller's `activity.log`, the grader's `grade.json` and the agent's whole conversation: Pi's `pi-events.jsonl` or the Claude Code transcript.
- **`claude-code-hooks.jsonl`** for a Claude Code run.
- **`manifest.json`:** every file with its size and SHA-256, written last. A folder without it is not complete.

A run already on the page whose logs are missing shows **Save run logs** instead, and a failure to save says so and can be retried. `Eab.RunLogs.save!/1` does the same outside the dashboard.

**The files are copied unchanged, with three replacements.** The repository is public, so the Claude account's organization ID, its email address and the names of the machine that served the model are replaced wherever they occur. A machine name with a dot or an `@` is replaced everywhere; a bare one only where it is written as an address, because a bare name could be an ordinary word. The first version of this rule replaced the word "subscription" throughout a Claude Code run's logs, since that run's endpoint is written `claude-code://subscription`.

**What is left out.** The controller's copies of every request and response repeat the conversation the event stream holds and are about 1.3 GB per local run. Each call's timing stays with the published result's own figures. The run's raw record names machines and GPUs.

## Considered options

- **Keep the logs only on the controller.** It costs nothing and is what failed: the data folder is one machine's Docker volume, not everyone's, and runs are made on more than one machine.
- **Keep them outside the repository,** as release assets or in other storage. The repository stays small, but the evidence is then a second thing to publish, link and keep alive, and a clone no longer holds what its results rest on.
- **Keep only derived numbers,** such as each call's tokens. That would have answered both questions above, and not the next one: what a model did when it failed, or how often it re-read a file.

## Consequences

- **The repository grows by about 60 to 80 MB per full run,** less once Git compresses the text. Three runs each of ten models is roughly 2 GB of working tree. If that becomes a burden the oldest folders can move elsewhere; their manifests say exactly what they held.
- **The controller needs the folder.** `compose.yaml` mounts the checkout's `verification/` into the container. Without the mount saving fails with a message; it never writes inside the container, where the files would be lost with it.
- **A run made on another machine arrives as files.** Its result file and its `verification/runs/run-<id>/` folder are carried to the repository together. `Eab.RunLogs.check/1` compares a carried folder with its manifest.
- **Logs saved by hand before this stay where they are:** the Claude Code runs under `verification/opus-validation-*`, `sonnet-series-*` and `haiku-series-*`. The four local-model runs made on v6 before this were saved with the same code into `verification/runs/` ([record](../../verification/local-series-2026-11-18/README.md)).
- **Patches are not reviewed by being saved.** The folder is evidence, not a judgement of it.
