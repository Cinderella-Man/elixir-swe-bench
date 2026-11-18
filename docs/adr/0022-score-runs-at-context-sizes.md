# Score each run at several context sizes

[ADR 0021](0021-give-each-case-a-token-allowance.md) limited an attempt's generated tokens to twice what Opus 5.5 needed on the case. It held the validator to that limit but not to the context window, and those are two different things. The window holds the whole conversation: the task, every tool result and every reply. In Opus's runs the conversation ends up about 2.3 times its generated tokens. Read from its saved transcripts, Opus's largest context was 298–307 thousand tokens on absinthe-pr-1176 in all three published runs, and 286 and 300 thousand in its two passes of ash-pr-3031 on the rewritten ticket. A local model gets 262,144. On those cases a local model could only pass by needing less context than the validator did, and on the seven largest cases the window, not the allowance, decided the outcome. See [how scores at context sizes work](../context-size-scoring.md) for the measurements.

The user proposed the remedy on 2026-11-17: hold every model to the same context, Opus included, and show what each model solves at each size.

Every attempt now records its **peak context**: the largest prompt any of its model calls was sent, plus that call's reply. History is never compacted, so that is the context the attempt needed. A published result can then be read at a **context size**:

- **The rule.** At a size, a case counts only if the agent finished on its own, its peak context is within that size, and its patch passes.
- **The sizes.** 65,536, 98,304, 131,072, 196,608 and 262,144 tokens: from what a small local setup holds to the largest window local runs use.
- **One run, every size.** Nothing is run or graded again. One run at the largest window gives the score at every smaller size, because each case's peak context is one recorded number.
- **The results page.** A **Context size** selector shows every series at the chosen size. **As run** stays the default and is each series' score as it was run, unchanged. Since 2026-11-18 the chart of a release with recorded peaks plots cases solved against context, one line per series, in place of cases against peak memory: that memory is measured with the whole window reserved, whatever the work needed, and hosted models have none. Memory stays in the table and the details.
- **What it measures.** How much room a model needs to do the work. Someone choosing hardware can read off what a model solves in the context they can afford.

This replaces ADR 0021's allowance as the benchmark's measure of economy. The allowance stays implemented and no release declares it. It derived a number per case from the validator's usage; a context size is the same for every model and every case, and needs none.

Read from the runs that exist (cases solved, of 20):

| Series | 65,536 | 98,304 | 131,072 | 196,608 | 262,144 | As run |
|---|---|---|---|---|---|---|
| Opus 5.5, its three v5 runs | 7, 7, 6 | 11, 11, 11 | 12, 12, 12 | 15, 15, 15 | 17, 16, 17 | 18, 17, 18 |
| Opus 5.5, its two assembled v6 runs | 7, 7 | 12, 12 | 13, 13 | 16, 16 | 18, 17 | 20, 19 |
| Sonnet 5.5 at max, its two assembled v6 runs | 0, 0 | 0, 0 | 2, 1 | 2, 3 | 9, 7 | 20, 20 |
| Haiku 5.5 at max, its two v6 runs | 0, 0 | 0, 0 | 2, 2 | 5, 5 | 10, 10 | 19, 19 |
| Qwen3.8-27B UD-Q4_K_XL, v6 | 5 | 9 | 13 | 16 | 16 | 18 |
| Qwen3.8-27B UD-Q6_K_L, v6 | 2 | 7 | 11 | 14 | 15 | 16 |

## Consequences

- **A size is stricter than the run itself.** A patch that passed when the window cut the attempt off counts in a series' own score ([ADR 0016](0016-limit-local-attempts-by-the-context-window-only.md)) but not at any size, because the agent did not finish. Qwen3.8-27B UD-Q4_K_XL scores 18 as run and 16 at 262,144.
- **These are "would have fit" scores.** The runs were made with a 262,144-token window and the models were told so. A model told it has 65,536 tokens might work differently.
- **Opus fails like any other model.** At 262,144 it loses absinthe-pr-1176, and ash-pr-3031 on the rewritten ticket. No case has to leave the release for being too large: each size shows who fits it.
- **Hosted models have no window to stop them.** Their own score includes attempts larger than any size here, and sizes above 262,144 are not offered because no local run can reach them.
- **Token units differ a little.** A hosted model's context is counted in its own tokens, a local model's in its own. A case near a size's edge can fall either side.
- **Reasoning a chat template drops costs no context.** Such a model fits more work into a size than one that keeps its reasoning in the conversation. Output tokens stay published beside the score.
- **Public schema 12.** Each case adds `peak_context_tokens`, null where the run did not record it. A series whose attempts all recorded it gets a score at every size; any other series is left out of a size's view. Series published earlier keep their files and are upgraded when they take another run.
- **Series already published.** The two Qwen3.8-27B v6 series had their peaks read from the per-call usage records their runs saved, and took schema 12. The DeepSeek v6 series' run logs are not on the controller's machine, so it has no scores at a size. The v5 series are left as published.
- **Opus and Sonnet on v6.** Neither has a full run on v6. At the user's request each has a v6 series assembled from its v5 runs and four single-case attempts, with its peaks read from their transcripts ([ADR 0012](0012-rebuild-release-and-validate-with-unpublished-opus-runs.md), amendments of 2026-11-17 and 18). Haiku 5.5's v6 series is two ordinary full runs, the first to record their peaks as they ran.
- **It does not separate economical models.** As run, every series above scores 16 to 20, and a size pulls the heavy users of context far below the rest: at 262,144 Sonnet and Haiku at max effort solve 7 to 10. But Opus and the two Qwen series still sit between 15 and 18 there. That needs cases that good models get wrong, which is a matter of what the cases ask, not of how they are scored.

## Considered options

- **Grade the patch as it stood when the attempt passed each size.** It credits work that was already done. But the harness keeps only the final patch, so the earlier state would have to be rebuilt by running the agent's commands again, which is not sure to reproduce the same files. And a half-finished patch passes or fails by where the cut falls.
- **Run every model once per size.** The model is then told the size it has, but each size costs a full run.
- **Leave out the cases Opus cannot fit in 262,144.** It removes two cases from every model's score to fix a problem that only the largest size has.
- **Compact the history when the window fills.** The window stops being a wall, but compaction changes what the harness does and lets attempts run for hours.
- **Keep the token allowance as the main measure.** It needs a number per case from the validator, and it leaves the validator outside the window.
