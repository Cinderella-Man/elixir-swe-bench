# v6 first results: why Qwen3.8-27B leads DeepSeek V4.1 Flash

Date: **2026-11-17**. Status: **continued**. This was a handoff note for the agent that continued this topic; nothing in the benchmark, cases or published results was changed for it, and no runs were started. What followed on the same day is in [how scores at context sizes work](../context-size-scoring.md): the results page can now show each series at smaller context sizes ([ADR 0022](../adr/0022-score-runs-at-context-sizes.md)), and ash-pr-3031 and livebook-pr-2800 got their [Opus validation](../../verification/opus-validation-2026-11-17/README.md). Of its suggested next steps, seeds 102 and 103 were not run, at the user's choice; step 4, harder cases, still stands.

## The question

Looking at the v6 results, the user found them "at least puzzling". DeepSeek isn't the best; the best is Qwen at Q4. What is going on, and how can it be explained?

## Short answer

1. **There is no ranking yet.** Each v6 series has 1 of its 3 required runs (ADR 0011). The scores are 18, 17 and 16 out of 20. All three models pass the same 15 cases and fail the same 2, so only 3 cases separate them. Qwen Q4 beating Qwen Q6 by 2 cases shows how large run-to-run luck is. Q6 is the same model with less compression, and it is 2 cases behind Q4, as far as DeepSeek is from either.
2. **v6 removed the token caps that held Qwen back in v5.** v5 capped each reply at 8,192 tokens and each attempt at 65,536 (ADR 0015, ADR 0016 removed both). Qwen at xhigh thinks long. In v5, 11 of Qwen Q6's 13 failures were cap cutoffs, and it scored 7/20. In v6 it scores 16. DeepSeek uses about half as many tokens, hit a cap once in v5, and moved only from 16 to 17.
3. **The DeepSeek being measured is heavily compressed and set up differently.** It is UD-IQ1_M, averaging about 2.7 bits per weight. It also uses an fp4 KV cache, an early Strata server build and effort "high", while Qwen ran at "xhigh". Qwen 27B at 5–7 bits per weight is close to full quality. None of these differences favours DeepSeek. Their individual effects are not measured.
4. **The benchmark is near its ceiling for these models.** Everyone passes 15 cases. In v5, Opus 5.5 and Sonnet 5.5 failed only 2–3 cases per run. With so few cases left to separate models, a 27B model can tie or beat a far larger one by one lucky case.

## The three v6 series

All three use Pi 1.2.0, a 262,144-token context window, no generation budget, no per-reply cap and seed 101, on identical case files.

| Series file (`results-page/results/`) | Model | Quant, bits/weight | Server, KV cache | Effort | Run | Score |
|---|---|---|---|---|---|---|
| `9d24395d….json` | Qwen3.8-27B | UD-Q4_K_XL, 5.2 | llama.cpp b1-7775ffb, q8_0 | xhigh | `20261117-072245-3bd94d5c` | **18/20** |
| `75a9990d….json` | DeepSeek-V4.1-Flash-1017 (748B, 16B active) | UD-IQ1_M, 2.7 | Strata ds4-0.1, fp4 | high | `20261113-193538-5205670a` | **17/20** |
| `c09888fc….json` | Qwen3.8-27B | UD-Q6_K_L, 7.1 | llama.cpp b1-7775ffb, q8_0 | xhigh | `20261116-113511-21de1916` | **16/20** |

Bits per weight are file size × 8 / parameter count. IQ1_M is a 1.75-bit format, and Unsloth's dynamic ("UD") mix keeps some tensors at higher precision; 250 GB for 748B parameters averages 2.7.

Further setup facts:

- **Same Qwen upload.** Both Qwen files come from the same upload: `unsloth/Qwen3.8-27B-GGUF` commit `acb953b1`, labelled v3.1, 2026-11-11. They share a chat template and sampling (temperature 1.0, top_p 0.95, top_k 20, min_p 0.05).
- **DeepSeek's sampling.** Its server reports only temperature 1.0 and top_p 1.0, with no top_k or min_p. Whether these are DeepSeek's recommended settings has not been checked.
- **DeepSeek's machine.** It ran on a 7-GPU host (5× RTX 3090 and 2× RTX 3080). The Qwen runs used 2× RTX 3090.

## Per-case outcomes

Token counts are generated tokens per case. "Context" means the attempt filled the context window, and its patch at that moment was graded.

| Case | DeepSeek IQ1_M | Qwen Q4 | Qwen Q6 |
|---|---|---|---|
| 15 cases* | all pass | all pass | all pass |
| accent-pr-183 | pass, 30k | pass, 62k | **fail**, 84k: 2 acceptance tests |
| absinthe-pr-1176 | pass, 95k | pass at **context**, 148k | **fail** at **context**, 152k: 14 of its own tests failing |
| beacon-pr-687 | **fail**, 38k, no budget hit | pass at **context**, 154k | pass at **context**, 155k |
| ash-pr-3031 | fail at context, 92k | fail, 160k | fail at context, 159k |
| vutuv-pr-1759 | fail, 74k | fail at context, 114k | fail at context, 134k |

\* The 15 cases are plausible-pr-5939, -6449 and -5956; livebook-pr-2219, -2527, -2663, -2800, -2822 and -3076; livebeats-pr-37; operately-pr-1069 and -1205; cachex-pr-341; guardian-pr-748; and pinchflat-pr-610.

Totals:

| | Avg tokens/case | Cases over 65k tokens | Hit the context limit |
|---|---|---|---|
| DeepSeek IQ1_M | 38k | 3 | 1 |
| Qwen Q4 | 71k | 8 | 3 |
| Qwen Q6 | 79k | 10 | 4 |

Two of Qwen Q4's 18 passes, absinthe and beacon, happened when the attempt filled the context window. The rules grade the patch at that moment, so these passes count. Whether such a patch passes depends on when the window fills, so these results are especially sensitive to luck. Counting only attempts that finished, the scores would be Q4 16, DeepSeek 17 and Q6 15.

## v5 versus v6

| v5 series (`results-page/releases/v5/`) | Score | Cutoffs | Failures that were cutoffs |
|---|---|---|---|
| Qwen3.8-27B UD-Q6_K_L, xhigh | 7/20 | 8 per-reply cap, 3 generation budget | 11 of 13 |
| DeepSeek-V4.1-Flash-1017 UD-IQ1_M, high | 16/20 | 1 generation budget | 1 of 4 |

In v5, Opus 5.5 through Claude Code scored 18, 17 and 18; it failed ash-pr-3031 every run, livebook-pr-2800 every run and vutuv-pr-1759 once. Sonnet 5.5 at max effort scored 18 and 18, failing ash-pr-3031 and guardian-pr-748. v6 rewrote the case texts of ash-pr-3031 and livebook-pr-2800 (commit `c7353971`), so those two cases are not directly comparable across releases.

Caveat: the v5 Qwen Q6 run recorded no sha256 for its weights. It was made on 2026-11-11, the day the v3.1 upload appeared. So it is not known whether v5 and v6 used the same Qwen file, and a changed file could be a second cause of the jump. Server build and chat template are the same.

## Shared failures worth a look

- **ash-pr-3031.**
  - All three v6 models fail 3–4 acceptance tests in `CalculationArgumentsTest`, `CalculationErrorsTest` and `CalculationPreservationTest`.
  - Every v5 Opus and Sonnet run failed it as well, though on the older case text.
  - It looks genuinely hard.
- **vutuv-pr-1759.**
  - Both Qwen runs fail exactly one acceptance test: `MentionEndpointsTest` "a NUL byte in q or handles is text that matches nothing".
  - That behaviour is a curator extension; see `cases/vutuv-pr-1759/provenance.json`.
  - The ticket covers it only through the sentence "Both answer `200` with a JSON body for any text in `q` or `handles`".
  - Before calling this a model failure, check whether that requirement is stated plainly enough. Any change to the case must follow [the case curation workflow](../case-curation-loop.md).
  - DeepSeek's reason for failing is unknown, because its grade is not available here.

## Ruled out

- **Different cases.** The `case_fixtures` hashes are identical in all three series.
- **Grading or agent code.** The series record different `code_version` values. That field is a hash over `lib/**/*.ex`, `priv/pi/*`, `priv/fixtures` and `mix.lock`, not a git commit.
  - Between the DeepSeek run (2026-11-13 19:35 UTC) and the Qwen runs, the code changes are:
    - `39c26c34` (ADR 0018): declares model file sources and hashes served files. It touches model source, memory collection, results and the dashboard, not the grader, Pi, sandbox or agent.
    - `6e2736ce`: Tailscale dashboard name; config only.
  - The v6 rules themselves (`32d6d9f7`, `e668d437`, `c7353971`) landed before the DeepSeek run.
- **Different Qwen weights between Q4 and Q6.** Both come from the same upload, with the same template, sampling and server.

## Not known yet

- **Why DeepSeek failed beacon-pr-687.** It stopped after 38k tokens and 54 calls without hitting any budget.
  - Its run directory `20261113-193538-5205670a` is not in this machine's data volume. Only the published summary is here.
  - Ask the user where that run was recorded.
- **How much each DeepSeek handicap costs.** The 2.7-bit average, the fp4 KV cache, effort "high" versus "xhigh", sampling with no top_k or min_p, and the early Strata build are confounded. A run that changes one of them would be a new series, not a fix to this one.
- **Run-to-run spread for local models on v6.** Every local series has a single run. Seeds 102 and 103 will give the first measurement. The results page draws a ±1.96 SE band once a series has two runs.
- **The vutuv-pr-1759 NUL-byte requirement.** See above.

## Suggested next steps (the user decides)

1. Run seeds 102 and 103 for all three series. The dashboard's **Contribute a run** fills the settings and a missing seed. Runs execute on the user's model hosts; do not start them unasked.
2. Before trusting any ranking among the top local models, compare paired per-case differences across the three runs, not totals.
3. For a fair DeepSeek comparison, one option is a new series at the same effort as Qwen, with a less compressed quant if the hardware allows. The other is to note these handicaps beside the result.
4. Longer term, add harder cases. With 15 of 20 cases passed by everyone, the release cannot separate strong models. See [the benchmark expansion plan](../benchmark-expansion-plan.md) and [the case curation workflow](../case-curation-loop.md).

## Constraints for whoever continues

- **v6 only.** The user cares only about v6 and will regenerate all results on it. Read `results-page/releases/v5/` for comparison, but never edit or backfill it.
- **No speed comparisons.** Per `AGENTS.md`, this machine must not be used for speed or performance comparisons. Published case times and model speed are not evidence for this question; leave them out.
- **Where the data is:**
  - The Qwen runs' full data, `grade.json` and `activity.log` per case, is in the Docker volume `elixir-agent-benchmark_benchmark-data`.
  - In container `elixir-agent-benchmark-benchmark-1`, it is under `/data/runs/<run-id>/<case>/`.
  - Read it with `docker exec … cat`, or copy it to a scratch folder; don't modify it.
- **Background reading:**
  - [Run-to-run variance research](run-to-run-variance-2026-10-26.md) covers error bars and paired comparisons.
  - [`docs/evaluation.md`](../evaluation.md).
  - ADRs [0011](../adr/0011-publish-three-run-series.md), [0015](../adr/0015-drop-the-per-reply-token-cap.md), [0016](../adr/0016-limit-local-attempts-by-the-context-window-only.md) and [0017](../adr/0017-discard-changes-outside-the-edit-area.md).

## Reproducing the tables

Per-case table of the published v6 series, from the repository root:

```bash
python3 -I - results-page/results/*.json <<'EOF'
import json, sys
series = []
for path in sys.argv[1:]:
    d = json.load(open(path))
    series.append((f"{d['model']['name'][:12]} {d['model']['quantization']}", d['runs'][0]['cases']))
print(f"{'case':20}" + "".join(f"{name:>32}" for name, _ in series))
for case in [c['id'] for c in series[0][1]]:
    row = f"{case:20}"
    for _, cases in series:
        c = next(c for c in cases if c['id'] == case)
        cell = ("PASS" if c['passed'] else "fail") + (" cut" if c['cutoff'] else "") + f" {c['generated_tokens'] // 1000}k"
        row += f"{cell:>32}"
    print(row)
EOF
```

Failing acceptance tests for one case in a Qwen run:

```bash
docker exec elixir-agent-benchmark-benchmark-1 cat /data/runs/20261116-113511-21de1916/accent-pr-183/grade.json \
  | python3 -I -c "import json,sys; g=json.load(sys.stdin); print([t for t,s in g['hidden']['test_results'].items() if s not in ('passed','excluded')])"
```
