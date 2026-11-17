# How scores at context sizes work

The results page can show every run series at a chosen **context size**: what the model solved when the whole attempt had to fit in that many tokens. This page explains the rule, how to read it, and how the benchmark got there on 2026-11-17. The decision itself is [ADR 0022](adr/0022-score-runs-at-context-sizes.md).

## The rule

Every attempt records its **peak context**: the largest prompt any of its model calls was sent, plus the reply that call generated. The conversation is never compacted, so it only grows, and the peak is what the attempt needed.

At a context size, a case counts as solved only if all three hold:

1. the agent finished on its own (nothing cut the attempt off);
2. the attempt's peak context is no larger than the size;
3. the patch passes every check.

The sizes are 65,536, 98,304, 131,072, 196,608 and 262,144 tokens. One run at the largest window gives the score at every smaller size. Nothing is run again and nothing is graded again: each case has one grade and one recorded peak.

| Attempt | Final grade | Peak context | Counts at |
|---|---|---|---|
| Opus 5.5 on livebook-pr-2800 | Passed | 74,187 | 98,304 and larger |
| Qwen3.8-27B UD-Q4_K_XL on livebook-pr-2219 | Passed | 125,834 | 131,072 and larger |
| Opus 5.5 on ash-pr-3031 | Passed | 300,199 | No size; only its own run |

## Reading the page

- **As run** is the default. It is each series' score exactly as it was run: for a local model, inside its own context window.
- **A size** replaces every score, interval and per-case count with that size's. The details then list each attempt's peak context beside its case.
- **A size is stricter than the run.** A local attempt that filled its window is cut off and its patch is still graded, so it can pass in the run's own score. At a size it never counts, because the agent did not finish. That is why Qwen3.8-27B UD-Q4_K_XL scores 18 as run and 16 at 262,144.
- **Series without recorded peaks are not shown at a size.** A note says how many.
- **These are "would have fit" scores.** The runs were made with a 262,144-token window, and the model was told that window. A model told it has 65,536 tokens might behave differently.
- **Token units differ a little.** Claude's tokens and a local model's are not the same unit, so a case near a size's edge can fall either side.

## What the existing runs show

Cases solved, of 20, in the v6 series.

| Series | 65,536 | 98,304 | 131,072 | 196,608 | 262,144 | As run |
|---|---|---|---|---|---|---|
| Opus 5.5, assembled run 1 | 7 | 12 | 13 | 16 | 18 | 20 |
| Opus 5.5, assembled run 2 | 7 | 12 | 13 | 16 | 17 | 19 |
| Qwen3.8-27B UD-Q4_K_XL | 5 | 9 | 13 | 16 | 16 | 18 |
| Qwen3.8-27B UD-Q6_K_L | 2 | 7 | 11 | 14 | 15 | 16 |

- **Small sizes spread the models out.** At 65,536 the range is 2 to 7.
- **Opus fails like any other model.** It never fits absinthe-pr-1176 or ash-pr-3031 in 262,144, so it solves 19 or 20 as run and 17 or 18 at that size.
- **At 262,144 they still cluster.** See [what this does not fix](#what-this-does-not-fix).

Opus's v6 series is assembled from attempts that already existed, not run as one. See [Opus on v6](#opus-on-v6).

The DeepSeek V4.1 Flash v6 series has no row. Its run was recorded on another machine, and only its published summary is here. An estimate from that summary puts it at about 4, 10, 15, 16 and 17, but the estimate can run 20% high per case, so it is not published.

## How the benchmark got here

### The puzzle

The first three v6 series scored 18, 17 and 16 of 20, with a 27B model at Q4 ahead of the same model at Q6 and of DeepSeek V4.1 Flash. [The first-results note](research/v6-first-results-2026-11-17.md) has the details. The differences were noise: each series had one run, and three cases separated them.

The cause was that v6 removed the token caps ([ADR 0016](adr/0016-limit-local-attempts-by-the-context-window-only.md)). In v5, 72 of the 97 failed local attempts were cap cutoffs, so the caps had produced most of the spread between models. Without them, every good model passes nearly everything. The two Qwen runs pass 629 and 626 of the release's 633 hidden tests.

### First answer: a token allowance

An attempt that may think for as long as its window lasts says little about day-to-day work. [ADR 0021](adr/0021-give-each-case-a-token-allowance.md) gave each case an allowance of generated tokens, twice what Opus 5.5 needed on it, and counted a case only if the agent finished inside it. Twice is the tightest round multiple that fails none of Opus's own attempts. The rule was built and left switched off until a release declares allowances.

### What it missed

Generated tokens and context are different limits.

- **Generated tokens are about waiting.** Generating is the slow part of an attempt.
- **Context is about capacity.** It holds the task, every tool result and every reply. In Opus's runs it ends up about 2.3 times the generated tokens.

The allowance held Opus to its generated tokens and to nothing else. Its saved transcripts record the context of every model call, and they showed that Opus itself does not fit the two largest cases in a local model's window:

| Case | Opus's peak context | Share of 262,144 |
|---|---|---|
| absinthe-pr-1176, three passes | 298k, 300k, 307k | 114–117% |
| ash-pr-3031, two passes on the rewritten ticket | 286k, 300k | 109–115% |
| vutuv-pr-1759 | 241k–255k | 92–97% |
| pinchflat-pr-610 | 199k–225k | 76–86% |
| guardian-pr-748 | 172k–184k | 66–70% |
| beacon-pr-687 | 170k–179k | 65–68% |
| cachex-pr-341 | 132k–167k | 51–64% |
| The other 13 cases | 30k–113k | 11–43% |

An attempt that spends twice Opus's output needs roughly twice Opus's context. That fits in 262,144 only when Opus peaked under 131,072, which holds for the 13 smaller cases. On the seven large ones the window cut in first, at between 0.85 and 1.57 times what Opus used. The limit was strict where the cases were large and loose where they were small, and on two cases a local model could pass only by being more economical than the validator.

Two fixes were considered and dropped. Scoring only the 13 smaller cases would have removed almost every case a good model gets wrong. Leaving out only the two cases Opus cannot fit would have changed every model's score to repair a problem that exists only at the largest size.

### The answer: one limit for every model

The user proposed holding every model to the same context, Opus included, and showing the score at several sizes. It needs no number per case and no validator-derived limit, and it answers a question people with real hardware have: what a model can do in the context they can afford.

## What this does not fix

A context size shows economy. It does not make good models differ at full size: at 262,144 the series above sit between 15 and 18 of 20.

Models separate at full size only on cases they get wrong, and the release has few of those. The ones it has are subtle, not large:

- **accent-pr-183:** 44 changed lines. It fails when the model writes its own version parser instead of using Elixir's.
- **ash-pr-3031:** fails on one rule, that a value already cast must not be cast again.
- **vutuv-pr-1759:** fails on a single edge input, a NUL byte.

New cases should be chosen for that kind of difficulty, and sized so that Opus's peak context stays well under 131,072 tokens. Then a size, not the window, is what limits them.

## Where the numbers live

| Place | What it holds |
|---|---|
| An attempt's record (`attempt.json`, `run.json`) | `peak_context_tokens` |
| The dashboard's case details | "Peak context" |
| A published series (schema 12) | `peak_context_tokens` for every case of every run, or null |
| The built page data | `by_context`: each series' score, interval and per-case counts at every size |
| `Eab.ContextSize` | The sizes, the rule and the calculation |

A run made before peaks were recorded can still supply them while its logs exist: a Pi run saved one usage record per model call, and a Claude Code run saved its transcript. That is how the two Qwen v6 series got theirs.

## Opus on v6

Opus 5.5 has not made a full run on v6. At the user's request its v6 series is assembled from attempts that exist:

- **18 cases** have identical files in v5 and v6. Their outcomes come from the first two runs of Opus's published v5 series.
- **ash-pr-3031 and livebook-pr-2800** had their tickets rewritten for v6. Their outcomes come from two single-case attempts each, made on 2026-11-17.

So each of its two runs is 18 October outcomes and 2 November ones. The October runs were made under v5's instructions, one sentence shorter than v6's, and on an older Claude Code version. No carried outcome depends on what v6 changed in grading. The series says "assembled" in its note and in the release note, and it never takes a real run: a full Opus run on v6 starts a separate series, after which the assembled one should be removed. [The validation record](../verification/opus-validation-2026-11-17/README.md#the-assembled-v6-series) lists exactly which attempt supplies which case, with the script that builds it.

## Still open

- **A full Opus run on v6.** It would replace the assembled series with a real one.
- **DeepSeek's peaks.** They need its run's logs from the machine that recorded it, or a new run.
- **The other v6 seeds.** Each local series still has one run of three.
- **Harder cases.** See above.
