# Python and Perl in the case containers, and two replies whose reasoning the server capped

Date: **2026-11-19**. Status: **analysis only**. Nothing in the benchmark, the cases or the published results was
changed for it, and no runs were started. The user asked two questions about the runs with saved logs:

1. How often did the agents try to use Python (or another interpreter) that the case container does not have?
2. Did the Strata server's thinking cap touch the published results, and where?

Both answers come from the 9 runs whose full logs were in `verification/runs/` (161 case attempts). On the same day v6 was
started again and those logs moved to [`verification/v6-archive-2026-11-19/runs/`](../../../verification/v6-archive-2026-11-19/README.md). The v5 runs have no
saved logs, so they are not covered.

| Run | Model | Server | Cases |
|---|---|---|---:|
| `20261113-193538-5205670a` | DeepSeek-V4.1-Flash-1017 UD-IQ1_M | Strata | 20 |
| `20261114-085614-515bd299` | DeepSeek-V4.1-Flash-1017-GSQ-RCO-Coder IQ2_XXS | Strata | 20 |
| `20261116-113511-21de1916` | Qwen3.8-27B UD-Q6_K_L | llama.cpp | 20 |
| `20261117-072245-3bd94d5c` | Qwen3.8-27B UD-Q4_K_XL | llama.cpp | 20 |
| `20261117-232211-330ad401` | Flint Q8_0 | llama.cpp (Flint build) | 20 |
| `20261118-072542-6db9af55` | Flint UD-Q4_K_XL | llama.cpp (Flint build) | 20 |
| `20261118-115818-69764904` | Qwen3.8-Flash-Next UD-IQ2_XS | Strata | 20 |
| `20261118-184224-6d451a46` | Qwen3.8-Flash-Next UD-IQ2_XS (rerun of beacon-pr-687) | Strata | 1 |
| `20261118-211234-9347bf7b` | Qwen3.8-27B Q8_0 | llama.cpp | 20 |

## Short answer

- **Python:** the agents tried to run Python in **108 of 161 case attempts** (125 calls), with every model. **None of
  the case images has Python**, so every call failed. Almost all were throwaway `python3 - <<'PY' … PY` scripts to
  search and replace in an Elixir file. It usually cost one tool call per case: after the failure the agents switched to
  their edit tool, `sed` or `perl` and rarely tried Python again. In one case (Flint Q8_0, `plausible-pr-5939`) the
  agent's last call was a failed Python edit, and it finished without noticing.
- **Perl:** used in 31 case attempts (174 calls). It is in the 17 cases on Ubuntu/Debian images and missing in the 3
  Plausible cases, which run on Alpine. It failed twice, both times on Alpine.
- **Node** was found every time the agents called it (133 calls).
- **The thinking cap** cut the reasoning of exactly **two replies** in all saved runs: one in `vutuv-pr-1759` of the
  Qwen3.8-Flash-Next run and one in `ash-pr-3031` of the DeepSeek GSQ-RCO Coder run. Both came at the very end of a
  case that was about to fill its context window, and **neither changed the case's grade** (details below). Every
  other reply was below its cap and came out as it would have without one.

## 1. Python and Perl

### What the case images contain

Every case runs in a `hexpm/elixir` image (`cases/<case>/case.json`, `runtime.image`): 17 cases on Ubuntu or Debian,
and the 3 Plausible cases (`plausible-pr-5939`, `-5956`, `-6449`) on `alpine-3.22.2`. None of the images has Python.
The Ubuntu and Debian images have Perl (`/usr/bin/perl`, Perl 5.36); Alpine does not.

### How often the agents tried them

"Cases" counts the case attempts in which the agent ran the program at least once. "Hidden" calls sent Python's error
to `/dev/null` behind a fallback (`2>/dev/null || sed …`), so they failed silently. "Probes" are `which` /
`command -v` checks that named Python.

| Run | Model | Cases with Python | Python calls (all failed) | of them hidden | Probes | Cases with Perl | Perl calls | Perl missing | sed calls |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `20261113-193538` | DeepSeek UD-IQ1_M | 16 / 20 | 20 | 0 | 3 | 5 | 59 | 0 | 425 |
| `20261114-085614` | DeepSeek GSQ-RCO Coder | 17 / 20 | 17 | 0 | 6 | 6 | 19 | 1 | 603 |
| `20261116-113511` | Qwen3.8-27B UD-Q6_K_L | 12 / 20 | 13 | 1 | 0 | 5 | 15 | 0 | 338 |
| `20261117-072245` | Qwen3.8-27B UD-Q4_K_XL | 8 / 20 | 9 | 1 | 1 | 1 | 16 | 0 | 315 |
| `20261117-232211` | Flint Q8_0 | 16 / 20 | 21 | 3 | 1 | 4 | 31 | 0 | 665 |
| `20261118-072542` | Flint UD-Q4_K_XL | 14 / 20 | 18 | 1 | 0 | 4 | 18 | 0 | 837 |
| `20261118-115818` | Qwen3.8-Flash-Next | 12 / 20 | 12 | 0 | 0 | 4 | 10 | 1 | 311 |
| `20261118-184224` | Qwen3.8-Flash-Next (rerun) | 1 / 1 | 1 | 0 | 0 | 0 | 0 | 0 | 16 |
| `20261118-211234` | Qwen3.8-27B Q8_0 | 12 / 20 | 14 | 2 | 0 | 2 | 6 | 0 | 240 |
| **All** | | **108 / 161** | **125** | **8** | **11** | **31** | **174** | **2** | **3,750** |

- **What the Python calls were:** 118 of the 125 piped a script on stdin (`python3 - <<'PY' … PY`), 3 ran a script
  file, 2 were `python3 -c` one-liners and 2 other forms. 107 of them edited files: read a file, `.replace()` or
  `re.sub()` a block, write it back. The output was `python3: command not found` (102 times) or `python: command not
  found` (15 times), or nothing for the 8 hidden calls.
- **What came next:** the tool call right after a failed Python call was the agent's edit tool 49 times, its write
  tool 8 times, `sed` 14, `perl` 12, a `cat > file <<'EOF'` rewrite 9, `mix` or `elixir` 6, another bash command 22,
  and Python again 4 times. Once it was the case's last call (below). In 14 of the 108 case attempts the agent ran
  Python more than once.
- **Perl missing:** `plausible-pr-5956` in the DeepSeek GSQ-RCO Coder run and `plausible-pr-6449` in the
  Qwen3.8-Flash-Next run, both Alpine. In both, the agent switched to its write or edit tool.

### What it means for the results

Every model ran in the same images, so the missing Python costs all of them alike: usually one wasted tool call per
case, plus the tokens of a script that never ran.

One case may have been lost to it. In the Flint Q8_0 run (`20261117-232211-330ad401`), the agent's last call in
`plausible-pr-5939` was a `python3 - <<'EOF'` script to edit `test/plausible_web/live/change_domain_test.exs`. It
failed with `python3: command not found`, and the agent then finished (`stop_reason: agent_completed`) with an empty
reply. The graded submission has no test (`submission.tests: 0`), and the case failed. Whether the edit would have made
it pass is not known.

If a later release wants to avoid this, the task instructions could say that Python is not installed, or the images
could include it. Either would change the environment the models are compared in, so it belongs to a new release, not
to v6.

## 2. The two replies whose reasoning was capped

### The cap

Strata's server (0.2.x) has a setting `answer_room`, on by default. When a request has a `max_tokens` and no thinking
budget of its own, Strata closes the model's thinking once it reaches 3/4 of that `max_tokens`, so the answer still
has room. The harness sends `max_tokens` = the context left (no per-reply cap since v6, ADR 0015), so the cut came at
3/4 of the remaining context. When it fires, the server logs
`[strata] thinking budget reached (N tokens): wrapping up the thinking` and writes this sentence into the model's
reasoning before `</think>`:

> I have thought about this long enough; time to give my answer.

The llama.cpp servers used for the other runs have no such default (`--reasoning-budget -1`, `--n-predict -1`).

### Where it fired

Two searches found the same two replies: the sentence above in every `pi-events.jsonl` of the 9 runs
(`grep -rl "I have thought about this long enough" verification/v6-archive-2026-11-19/runs`), and the "thinking budget reached" lines in
both Strata servers' logs for the run dates. The other two Strata runs (DeepSeek UD-IQ1_M and the Flash Next rerun) have none.

| | Qwen3.8-Flash-Next, `vutuv-pr-1759` | DeepSeek GSQ-RCO Coder, `ash-pr-3031` |
|---|---|---|
| Run / series file | `20261118-115818-69764904` / `results/3001866d….json` | `20261114-085614-515bd299` / `results/236af9a3….json` |
| Reply | 76 of 78, about 18:26 UTC on 2026-11-18 | 144 of 145, about 13:45 UTC on 2026-11-14 |
| Prompt at that reply | 256,999 tokens (98.0% of 262,144) | 259,555 tokens (99.0%) |
| Room left (`max_tokens`) | 5,137 | 2,581 |
| Thinking cut at | 3,853 tokens | 1,936 tokens |
| What followed | a short text and a read-only `grep`; reply 77 another `grep`; reply 78 filled the context (`length`) | the same reply ran out of room inside a `bash` call that rewrote a test file; reply 145 found the context full |
| Case end | `stop_reason: context_budget` | `stop_reason: context_budget` |
| Grade | failed | failed |

### Why neither grade changed

- **vutuv-pr-1759.** After the cut, the agent ran only two read-only `grep` calls before the context filled, so the
  graded patch is the one from before reply 76. Without the cap, reply 76 would have gone on thinking until the
  context ended, with the same patch graded.
- **ash-pr-3031.** The test file that the capped reply's `bash` call wrote is not in the graded patch
  (`model.patch`). The submitted test is `test/calculations/temp_test.exs`, and the hidden tests fail on
  implementation errors (`Protocol.UndefinedError` for `Ash.Query.Ref`), not on a broken file. The context was full
  in that same reply with or without the cap.

### Status

Since 2026-11-19 the Strata service for Qwen3.8-Flash-Next sets `"answer_room": false` and
`"reasoning_budget_tokens": 0`, so the cap no longer fires; the DeepSeek Strata deployment used on 2026-11-14 is no
longer set up. Rerunning the two cases with the cap off would remove any doubt. It would also be a new sample: the
agent's path through the case would differ from the first run, as for any rerun. Whether to rerun is the user's call;
these results do not require it.

## How to repeat the counts

From the repository root:

```bash
python3 docs/research/agent-tools-and-capped-reasoning-2026-11-19/count_tools.py verification/v6-archive-2026-11-19/runs counts.json
```

It prints one line per run (the table above), then the totals, including the "what came next" breakdown, and writes
the per-run numbers to `counts.json`. The script's header explains the rules. The breakdown of the Python calls by kind
(stdin script, `-c`, script file, file edits) used the same rules and is not in the script.
