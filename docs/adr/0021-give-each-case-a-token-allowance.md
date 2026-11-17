# Give each case a token allowance

Status: implemented and unused. [ADR 0022](0022-score-runs-at-context-sizes.md) made context size the benchmark's measure of economy, and no release declares allowances.

Since [ADR 0016](0016-limit-local-attempts-by-the-context-window-only.md) only the context window limits a local attempt. The first three v6 series then scored 18, 17 and 16 of 20, and their differences are noise. The two Qwen3.8-27B runs pass 629 and 626 of the release's 633 hidden tests. On the 13 cases with short tickets, 38 of 39 attempts pass. An attempt may think for as long as the window lasts, so the score says a model gets there eventually. It does not say whether the model is usable for day-to-day work, where someone is waiting for the answer. See [the v6 first-results note](../research/v6-first-results-2026-11-17.md).

The cases are not too easy for that question; the missing limit is. The same three runs were rescored on 2026-11-17, counting a pass only when the agent finished on its own and generated no more than a multiple of what Opus 5.5 needed on that case (the median of its three published runs, at least 16,384):

| Limit | 1.25× | 1.5× | 2× | 3× | 4× | 6× | None |
|---|---|---|---|---|---|---|---|
| DeepSeek V4.1 Flash UD-IQ1_M, high | 16 | 17 | 17 | 17 | 17 | 17 | 17 |
| Qwen3.8-27B UD-Q4_K_XL, xhigh | 5 | 7 | 13 | 14 | 16 | 16 | 16 |
| Qwen3.8-27B UD-Q6_K_L, xhigh | 5 | 5 | 10 | 11 | 13 | 15 | 15 |
| Opus 5.5 (its three runs) | 18, 16, 17 | 18, 16, 18 | 18, 17, 18 | same | same | same | 18, 17, 18 |

The order of the models is the same at every multiple. DeepSeek spends about what Opus does (median 1.0× per case, never above 1.7×). Qwen's median case takes 1.6–1.7×, and its worst cases 3.4× and 5.2×. These numbers are an estimate: the runs were neither told about a limit nor stopped at one, and the two models ran at different thinking efforts.

A release may therefore give every case a **token allowance**: the most tokens an attempt at it may generate, reasoning and tool syntax included.

- **Size.** A case's allowance is twice the median of what the release's validator generated on it, and at least 16,384 tokens. Twice is the tightest round multiple that fails none of the validator's own attempts: Opus's worst of 60 used 1.99× its median, and at 1.5× it loses a pass. ADR 0016 removed the flat 65,536-token budget because the validator itself exceeded it on a third of the release; an allowance sized from the validator's own usage cannot have that fault.
- **Where it lives.** The rule and the validator's token counts are in the release's inventory, under `allowance` in `config/benchmark.json`. They cannot live in the case files: the validator's attempts are made on the frozen case files, so a number derived from those attempts would change the files it was measured on.
- **What the agent is told.** Its instructions name the allowance and say that an attempt which uses it up, or runs out of context, counts as failed whatever its patch.
- **Stopping.** The gateway stops a local attempt at its allowance. A hosted Pi run is checked between replies, so its last reply can go over. Claude Code cannot be stopped, so its transcript's usage is checked afterwards.
- **Passing.** A case passes only if the agent finished on its own, generated no more than the allowance, and its patch passes. Filling the context window fails the case as well. Without this, a cut-off attempt passes or fails by where the cut falls: in v6 one Qwen run failed absinthe-pr-1176 with all 114 hidden tests passing, because the window filled while it was fixing its own test file.
- **The patch is still graded.** The grader's verdict on the patch is recorded beside the case outcome, so results separate a wrong answer from a right one that came too late.

The rule is dormant until a release declares allowances. `elixir-agent-benchmark-v6` declares none, so its runs, series and published results are unchanged. A run reads the allowances of its own frozen release, so a resumed run keeps the ones it started with. This replaces ADR 0016's rule only for releases that declare allowances.

## Consequences

- **Series.** The allowances join a series' setup, so runs made under different allowances never join, and a page takes only series made under the current release's. Series of a release without allowances keep their IDs.
- **Public schema 11.** Each case adds `patch_passed`, the grader's verdict on the patch alone. Series published earlier keep their files and are upgraded when they take another run; before 11, a case's outcome was its patch's verdict. The allowances are published in the series' `setup`.
- **Thinking effort becomes a real choice.** Without a limit, the highest effort is always best. Under an allowance a lower effort can score higher, and each effort is its own series.
- **Runs get little shorter.** Stopping the two Qwen runs at 2× would have saved 3–8% of their tokens: their totals are only 1.4–1.6 times Opus's. The allowance changes what counts far more than how long a run takes.
- **Sonnet 5.5 at max effort.** It generated 2.3–12.3 times Opus's median on every case, so at that effort it would pass nothing. It needs a series at a lower effort.
- **Claude Code.** Its usage comes from the transcript and is best effort, and an attempt that goes over is failed only after it ends. Claude Code also reminds its model of the tokens used; Pi tells the model the allowance once and nothing after.
- **The validator is the yardstick.** Its runs fit their allowances by construction, which favours it, as validating the cases already does.
- **Cases the validator never passed.** ash-pr-3031 has no Opus pass, so its allowance comes from failed attempts. It and livebook-pr-2800 had their tickets rewritten for v6 and need Opus attempts on the new text before a release can state their allowances.
- **Speed runs.** They stop at the allowance like any attempt, so a speed case's time covers at most its allowance.

## Considered options

- **A flat budget for every case, as before ADR 0016.** One number is too small for the large cases or too large for the small ones. 65,536 scores these runs 16, 12 and 10, but it is below Opus's own median on seven cases, where it would again measure itself.
- **No limit, and publish token use beside the score.** Nothing is cut and every figure is honest, but the score still says every good model passes nearly everything.
- **Apply the allowance afterwards without stopping attempts.** It keeps the full token curve, but the model host keeps working on attempts that have already failed, and the model cannot plan for a limit it was not told.
- **A wall-clock limit.** It is what a waiting person feels, but it depends on the model host's speed, which this benchmark does not score.
- **The allowance in each case's `case.json`.** It keeps the number with the case, but it changes a file the validator's attempts are bound to and sends every case through admission again.
- **Another multiple.** 1.5× fails the validator's own passes. 3× gives nearly the same scores as 2× and is the looser of the two.
- **Count a cut-off attempt whose patch passes.** It rewards an attempt for where the cut happened to fall.
- **Tell the model how many tokens it has used as it goes.** The benchmark would be writing text into the conversation, which [ADR 0015](0015-drop-the-per-reply-token-cap.md) declined for the same reason.
