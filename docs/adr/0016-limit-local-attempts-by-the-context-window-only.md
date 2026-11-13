# Limit local attempts by the context window only

Local Pi runs gave every attempt 65,536 generated tokens. An audit of the recorded runs on 2026-11-13 found that this budget, not the model, decided a large share of local outcomes:

- **Failures:** in the ten published local series (200 attempts), 44 of the 97 failures ended on the generation budget. Another 28 ended on the 8,192-token reply cap that [ADR 0015](0015-drop-the-per-reply-token-cap.md) removed, and those attempts would now run into the budget instead. Only 24 failures were attempts where the model finished and was wrong.
- **Pass rates:** attempts that finished on their own passed 79% of the time; attempts cut by the budget passed 19%.
- **The validator under the same budget:** Opus 5.5 generated more than 65,536 tokens in 18 of the 53 passes of its published series, and Sonnet 5.5 in 32 of its 36. On seven cases Opus's median usage is above the local budget; local models pass 14 of 70 attempts there and 89 of 130 on the other thirteen cases.
- **Other harnesses:** ChatGPT and Claude Code runs declare 262,144 generated tokens, checked softly or not at all.

Harder cases need more tokens and also fail more, so not every cut-off attempt would have passed. But a limit that even the validating model exceeds on a third of the release measures itself, as the reply cap did.

A local attempt therefore has no generation budget. It ends when the agent finishes, or when the conversation no longer fits the context window:

- **Reply limit:** each request may generate as much as the prompt leaves free in the context window.
- **Stopping:** the model is stopped before a call only when the prompt leaves no room, which is a context cutoff.
- **Agent instructions:** they name the context window as the only limit.
- **Dashboard:** a local run has no generated-token setting. Context size and seed remain.
- **Hosted models:** ChatGPT, Claude API and Claude Code runs keep their 262,144 generated-token threshold. The controller cannot count their context exactly, so that threshold is their only declared bound.
- **Pi's reply wait:** Pi's own HTTP timeout is off. The bridge hands Pi each reply in one piece, so a 21-minute timeout that the 8,192-token cap had made harmless would now end long replies as evaluation errors. The gateway still fails a request once the model server has been silent for 20 minutes.

## Consequences

- **Series.** The generation budget is a run setting, so local runs made with it and without it belong to different series ([ADR 0011](0011-publish-three-run-series.md)). Local series made with a budget take no more runs. Every one of them already had the reply cap, so ADR 0015 had closed them.
- **Release.** This change ships with the case corrections of 2026-11-13 as benchmark `elixir-agent-benchmark-v6`. The v5 series move to `results-page/releases/v5/`, where they stay on the results page as an earlier release, and as its primary one until v6 has enough series to take over.
- **Older runs.** A run made with a budget keeps it when it is resumed, and keeps its old instruction sentence.
- **Long attempts.** Nothing bounds an attempt's generated tokens or duration except the context window. History is never compacted, so every call adds to the prompt and an attempt always ends, but a model that loops through small tool calls can run for hours. **Stop run** remains the remedy.
- **Chat templates that drop earlier reasoning.** Their prompts grow more slowly than their output, so such a model may generate more than the window holds before the conversation fills it. That is allowed: the window bounds the conversation, not the output.
- **Results schema.** A local series records `max_tokens: null`, shown as "No cap". The `generation_budget` cutoff stays for the v5 series and for hosted Pi runs.
- **Unused defaults.** `config/benchmark.json` drops its `response_tokens` and `max_tokens` defaults. The case changes already end in-place retries of earlier runs, which was the reason ADR 0015 kept the unused default.

## Considered options

- **Raise the budget to 262,144, as hosted runs declare.** It still ends attempts at a number chosen by the benchmark: Sonnet 5.5 went past it in 9 of 40 attempts and passed 7 of those.
- **Set the budget to the context window size.** The same number as the window, but a second limit that binds differently when a chat template drops earlier reasoning.
- **Keep 65,536 and tag cut-off attempts.** The tags already existed. The scores would go on measuring the budget.
- **A wall-clock limit per attempt.** It would bound runaway attempts, but it depends on the model host's speed, which this benchmark does not measure.
