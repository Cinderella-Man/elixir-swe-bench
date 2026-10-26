# Run-to-run variance in LLM and coding-agent benchmarks

Research date: **2026-10-26**. This note records how established benchmarks, leaderboards, evaluation frameworks and model developers handle different scores from repeated evaluations of the same model. It is evidence for a later decision by the user. It does not choose a design or change the benchmark. No benchmark, model evaluation, build or timing measurement was run for it.

Sources are papers, official repositories and documentation, leaderboard methodology pages, inference-server documentation, and model developers' own launch posts and system cards. Repositories are pinned to the commit inspected. Arithmetic in §6 was computed for this note from the cited formulas. Statements marked **Inference** are reasoning from the sources, not something a source states. Methodology wording is paraphrased; the note keeps one short direct quotation.

## Scope and terms

Sources use "variance" for different things. Keep them apart when reading the rest of this note:

| Source of variation | What changes between two evaluations | Typical evidence |
|---|---|---|
| Case (question) sampling | Which cases are in the benchmark | Standard error over cases; bootstrap over cases |
| Within-case sampling | The model's answer to the same case | Repeated attempts per case |
| Inference numerics | Bits of the computation for the same request | Identical requests giving different outputs |
| Infrastructure | Resource limits, timeouts, provider behavior | Score shifts with configuration or time |
| Training seed or checkpoint | The model weights themselves | Several training runs or checkpoints |

The first two terms add up to the variance of a single-attempt score; repeated attempts reduce only the second ([Miller, §3](https://arxiv.org/html/2411.00640)). The lm-eval-harness authors make the same distinction. Their default bootstrap answers how scores would vary if new questions were drawn from the same distribution. Rerunning a stochastic model answers a different question; they regard both as useful ([Biderman et al., §4](https://arxiv.org/html/2405.14782)).

## 1. Statistical reporting guidance

### Miller, "Adding Error Bars to Evals" (Anthropic, arXiv 2411.00640v1, 1 November 2024)

The paper treats evaluation questions as a sample from an unseen super-population. It gives the standard error of the mean as `sqrt(Var(s)/n)`. For binary scores this becomes `sqrt(p(1-p)/n)`, with a 95% interval of `mean ± 1.96·SE`. It recommends reporting the standard error under the mean. [§2.1](https://arxiv.org/html/2411.00640)

When questions come in related groups, it recommends clustered standard errors. Ignoring clustering overstates precision. In its examples, clustered SEs reach about three times the naive value (DROP). [§2.2, Table 4](https://arxiv.org/html/2411.00640)

The variance of the mean decomposes as `(Var(x) + E[σᵢ²]) / n`. Here `x` is a question's expected score (between-question variance) and `σᵢ²` is the conditional variance of answers to one question (within-question variance). Resampling each question K times divides only the within term by K. In a worked example with uniformly distributed difficulty and binary scores, K = 2, 4 and 6 cut the variance of the mean by 1/3, 1/2 and 5/9; the limit is 2/3. Once `E[σᵢ²]/K` is small relative to `Var(x)`, more resamples barely help. Computing a standard error as if all K·n answers were independent is inconsistent. [§3–3.1](https://arxiv.org/html/2411.00640)

It recommends next-token probabilities where they exist, otherwise choosing K. The sampling temperature should not be changed merely to reduce score variance. [§3.2–3.3](https://arxiv.org/html/2411.00640)

For comparing two models, it recommends paired per-question differences wherever practicable. The paired SE equals `sqrt(SE_A² + SE_B² − 2·SE_A·SE_B·Corr)`; with a question-level correlation of 0.5, the variance falls by a third. [§4](https://arxiv.org/html/2411.00640)

Power analysis uses `n = (z_{α/2} + z_β)² (ω² + σ_A²/K_A + σ_B²/K_B) / δ²`. Equivalently, the minimum detectable effect is `δ = (z_{α/2} + z_β) · sqrt((ω² + σ_A²/K_A + σ_B²/K_B) / n)`, where `ω² = Var(x_A) + Var(x_B) − 2Cov(x_A, x_B)`. In its examples, detecting 3 points with no within-question variance and ω² = 1/9 needs about 969 questions. With n = 198, raising K from 1 to 10 lowers the minimum detectable effect from 13.2% to 7.5%. It suggests new evaluations contain at least 1,000 questions. [§5, Eqs. 9–10](https://arxiv.org/html/2411.00640)

Epoch AI's error bars cite this paper ([Epoch Benchmarking Hub FAQ](https://epoch.ai/benchmarks/about)).

### Other guidance

**Madaan et al., "Quantifying Variance in Evaluation Benchmarks" (Meta, arXiv 2406.10229v1, June 2024).** Its "seed variance" is a **training-time** quantity. It is the standard deviation across ten Llama-2-7B-architecture models trained from scratch with different initialization seeds. It does not measure sampling at inference. Seed variance was below the average 95% interval for most benchmarks (HumanEval 1.11 vs 3.98 points) but close to it on MMLU (0.57 vs 0.72). IRT-based 100-item subsets raised seed variance (ARC-C 0.80 to 1.80) and flipped about 12% of pairwise model comparisons; the authors caution against IRT for model comparison. [§2–5](https://arxiv.org/html/2406.10229)

**Heineman et al., "Signal and Noise" (Allen Institute for AI and University of Washington, arXiv 2508.13144v1, August 2025).** "Noise" is the relative standard deviation over the final 30 checkpoints of one training run. It serves as a proxy for seed and data-order noise, not inference-time sampling. "Signal" is relative dispersion across models. A higher signal-to-noise ratio predicted better small-scale decisions. Filtering to higher-ratio subtasks improved decision accuracy even though it reduced instance counts, and the authors note larger benchmarks are not necessarily better. [§3, §5.1](https://arxiv.org/html/2508.13144)

**Biderman et al., "Lessons from the Trenches" (EleutherAI lm-evaluation-harness, arXiv 2405.14782, v3 May 2026).** The harness reports bootstrapped standard errors by default to make interval reporting routine. The authors also recommend multiple random seeds and significance testing where affordable. [§4](https://arxiv.org/html/2405.14782)

**Zhu et al., Agentic Benchmark Checklist (arXiv 2507.02825v5, August 2025).** Reporting item R.10 asks benchmarks to report statistical significance, such as confidence intervals ([checklist](https://arxiv.org/html/2507.02825)). Terminal-Bench's own checklist self-assessment credits repeated runs and reported intervals with mitigating reproducibility issues ([Terminal-Bench paper, appendix B.5](https://arxiv.org/html/2601.11868)).

## 2. Metrics over repeated attempts

### pass@k: capability with retries or selection

Chen et al. define pass@k as a problem counting as solved if any of k samples passes its unit tests. Drawing exactly k samples gives a high-variance estimate. The paper therefore generates n ≥ k samples (n = 200, k ≤ 100), counts c correct, and uses the unbiased estimator `1 − C(n−c, k)/C(n, k)`, averaged over problems. The naive `1 − (1 − p̂)^k` is biased (appendix A). Figure 3 gives a numerically stable implementation. [Codex paper, §2.1](https://arxiv.org/pdf/2107.03374)

The best temperature rises with k: for a 679M-parameter model, T* = 0.2 for pass@1 and 0.8 for pass@100. The paper also reads pass@k as best-of-k with an oracle that knows the tests. [§3.3](https://arxiv.org/pdf/2107.03374)

### pass^k: reliability across repeats

τ-bench defines pass^k ("pass hat k") as the chance that **all** k independent trials of a task succeed, averaged over tasks. Its estimator is `E_task[C(c, k)/C(n, k)]`. It contrasts this with pass@k's at-least-one success. Main results use at least three trials per task. The agent runs at temperature 0.0, while the LLM user simulator runs at 1.0 so that reruns vary. gpt-4o's retail pass^1 of about 61% falls below 25% at pass^8. [τ-bench, §3 and §5](https://arxiv.org/html/2406.12045)

Anthropic's agent-evaluation guide (9 January 2026) makes the same distinction. pass@k rises with k and fits cases where one working solution suffices; pass^k falls with k and fits customer-facing agents that must behave consistently. Its example: a 75% per-trial success rate gives about 42% pass^3. The two metrics are equal at k = 1. [Demystifying evals for AI agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)

### Implementations

- Inspect reduces repeated "epochs" of each sample before metrics run, with `mean` as the default. Built-in reducers include `pass_at_{k}` (citing Chen et al.), `pass_k_{k}` (citing τ-bench) and `at_least_{k}`. [Inspect scoring metrics](https://inspect.aisi.org.uk/metrics.html)
- Terminal-Bench's leaderboard computes pass@2 through pass@5 with the unbiased estimator, alongside accuracy. [Leaderboard metrics source](https://github.com/harbor-framework/terminal-bench/blob/e67a2cb7db4d9795c212909b3395d8c22ad60aec/leaderboard/src/leaderboard/core/metrics.py)
- Artificial Analysis headlines AA-AnalystAgent with pass^5: the share of questions correct in all five repeats. It also computes pass@1 and pass@5 to separate reliability from ceiling. Its other evaluations use pass@1 averaged across repeats. [AA methodology v4.3.2](https://artificialanalysis.ai/methodology/intelligence-benchmarking)
- The SWE-bench leaderboard rejects pass@k submissions, in which any of several evaluated attempts counts. It accepts best@k when a distinct component chooses the submitted attempt without evaluation results. [Submission checklist](https://github.com/SWE-bench/experiments/blob/40f164d5b8f1d249bf95a6df8b74b577fd8e519d/checklist.md)

**Inference:** with independent attempts and a per-case success probability of 0.8, pass@3 = 0.992 while pass^3 = 0.512 and pass^5 = 0.328. Mean pass rate (pass@1 averaged over K attempts) estimates per-attempt success; pass@k and pass^k answer the ceiling and consistency questions respectively.

## 3. What benchmarks, leaderboards and frameworks do

| Benchmark or tool | Attempts behind a published score | Uncertainty reported | Source |
|---|---|---|---|
| SWE-bench leaderboards | One submitted prediction per instance; `attempts: 1` or `2+` declared | No interval on the leaderboard or in submission rules | [Checklist](https://github.com/SWE-bench/experiments/blob/40f164d5b8f1d249bf95a6df8b74b577fd8e519d/checklist.md), [README](https://github.com/SWE-bench/experiments/blob/40f164d5b8f1d249bf95a6df8b74b577fd8e519d/README.md) |
| Terminal-Bench 2.0 paper | At least five runs per model-agent pair; 32,155 trials | 95% intervals; method not stated | [Paper §3, Table 2](https://arxiv.org/html/2601.11868) |
| Terminal-Bench 4.0 leaderboard | All tasks, at least 5 trials each; errored trials count as 0 | Accuracy ± 1.96·SE, with SE from within-task variation only | [SUBMIT.md](https://github.com/harbor-framework/terminal-bench/blob/e67a2cb7db4d9795c212909b3395d8c22ad60aec/leaderboard/SUBMIT.md), [metrics.py](https://github.com/harbor-framework/terminal-bench/blob/e67a2cb7db4d9795c212909b3395d8c22ad60aec/leaderboard/src/leaderboard/core/metrics.py) |
| Aider leaderboards | One benchmark run per entry; `--tries` gives pass_rate_1/2 | None on the current page; 2023 page showed a 10-run range | [Leaderboard](https://aider.chat/docs/leaderboards/), [benchmark README](https://github.com/Aider-AI/aider/blob/2dec862ea6ebbc8a1c93bc29504674e09e5fa3dc/benchmark/README.md), [2023 page](https://aider.chat/docs/benchmarks.html) |
| LiveCodeBench | 10 samples per problem at T = 0.2, top_p 0.95 | Not reported | [Paper](https://arxiv.org/html/2403.07974) |
| METR time horizons | About 8 runs per agent and task | Hierarchical bootstrap over task families, tasks and runs | [Paper](https://arxiv.org/html/2503.14499) |
| Epoch AI hub | Multiple runs (16 for GPQA Diamond, 8 for MATH Level 5); SWE-bench run count not stated | ±1 SE following Miller | [FAQ](https://epoch.ai/benchmarks/about), [SWE-bench Verified page](https://epoch.ai/benchmarks/swe-bench-verified) |
| Artificial Analysis v4.3.2 | Per evaluation: Terminal-Bench 4.0 and SciCode 3, τ³-Banking 5, HLE 1 | Intervals only for Elo-based evaluations | [Methodology](https://artificialanalysis.ai/methodology/intelligence-benchmarking) |
| HELM (2022–2023) | 3 random sets of in-context examples; 1,000 instances per scenario | Range across seeds; authors flag significance limits | [Paper](https://arxiv.org/abs/2211.09110) |
| HAL | Single runs for most evaluations | None for most evaluations | [Paper](https://arxiv.org/html/2510.11977) |
| lm-evaluation-harness | One generation per document unless `repeats` set | Item-level SE by default | [metrics.py](https://github.com/EleutherAI/lm-evaluation-harness/blob/d6de81643928d653435c431bae19945d41d32520/lm_eval/api/metrics.py) |
| Inspect | `--epochs` (default 1) with a reducer | `stderr`, clustered `stderr`, `ci`, `ci_wilson` | [Metrics](https://inspect.aisi.org.uk/metrics.html), [options](https://inspect.aisi.org.uk/options.html) |

### SWE-bench

The checklist requires a pass@1 submission. Best@k submissions must declare `attempts: "2+"`, and their trajectories must include every rollout and the selection mechanism. The checklist's Best@1 definition says that, across multiple runs, the count is the number of instances solved in every run. No inspected document says how often the leaderboard receives or applies multi-run Best@1 submissions. For an optional "verified" checkmark, maintainers rerun the submitter's system on a random subset; the README does not describe a tolerance for run-to-run differences. Reasoning traces became mandatory on 29 July 2024, and Verified and Multilingual became limited to academic and research submissions on 18 November 2025. [Checklist](https://github.com/SWE-bench/experiments/blob/40f164d5b8f1d249bf95a6df8b74b577fd8e519d/checklist.md), [README](https://github.com/SWE-bench/experiments/blob/40f164d5b8f1d249bf95a6df8b74b577fd8e519d/README.md)

### Terminal-Bench

The 2.0 paper (January 2026) ran each supported model-agent combination at least five times and reports resolution rates with 95% intervals; it does not state the interval method. [§3, appendix A](https://arxiv.org/html/2601.11868)

For 4.0 (28 August 2026), submissions must run the pinned dataset with default timeouts and resources. They must cover every task with at least five trials. Errored trials count as reward 0. Community submissions are currently closed. The leaderboard computes accuracy as successful trials divided by all trials. Its standard error is `sqrt(Σᵢ pᵢ(1−pᵢ)/(kᵢ−1)) / n` over tasks i with observed pass rate pᵢ and kᵢ trials, and the interval is ±1.96·SE. This formula contains only within-task variation; it does not include task-sampling variance. [SUBMIT.md](https://github.com/harbor-framework/terminal-bench/blob/e67a2cb7db4d9795c212909b3395d8c22ad60aec/leaderboard/SUBMIT.md), [metrics.py](https://github.com/harbor-framework/terminal-bench/blob/e67a2cb7db4d9795c212909b3395d8c22ad60aec/leaderboard/src/leaderboard/core/metrics.py)

The 4.0 release calibrated task resources and set a flat 8-hour timeout to reduce timeouts and errors as noise. It removed tasks every latest-generation model solved 5/5 times, and it treats task-set or environment changes as breaking changes that require re-running trials. [Terminal-Bench 4.0 announcement](https://www.tbench.ai/news/terminal-bench-4-0)

### Aider

An early code-editing benchmark page (undated; gpt-3.5-turbo-0613 era) says the harness sends identical requests on repeated runs. It found OpenAI's chat API was nondeterministic even at temperature 0, usually producing fewer than 5–10 distinct responses. It ran all 133 exercises 10 times against one model and drew the range as error bars. Its second try sends the failing test output back to the model, so pass_rate_2 is a feedback retry, not pass@2 in Chen's sense. [Benchmark page](https://aider.chat/docs/benchmarks.html)

The current leaderboard (last updated 20 November 2025) shows one result per entry and does not describe repeats or intervals. [Leaderboard](https://aider.chat/docs/leaderboards/), [README](https://github.com/Aider-AI/aider/blob/2dec862ea6ebbc8a1c93bc29504674e09e5fa3dc/benchmark/README.md)

### METR

METR performs about eight runs per agent-task pair; the count is approximate because of infrastructure failures. Tasks are weighted by the inverse square root of family size. Intervals come from 10,000 samples of a three-level bootstrap over task families, then tasks, then runs. Its sensitivity analysis separates limited tasks from run-to-run variance. [arXiv 2503.14499, v4 July 2026, §2.3 and §3](https://arxiv.org/html/2503.14499)

### Epoch AI

Internal runs use Inspect and API-default temperatures. Most models run 16 times on GPQA Diamond and Mock AIME, and 8 times on MATH Level 5. Plots show ±1 SE following Miller. [FAQ](https://epoch.ai/benchmarks/about)

Its SWE-bench Verified page uses 484 of 500 samples that run reliably on its infrastructure. A scaffold upgrade (v2.0.0, 12 February 2026) re-evaluated key models. The page does not state runs per sample or the interval method. [SWE-bench Verified methodology](https://epoch.ai/benchmarks/swe-bench-verified)

### Artificial Analysis (Intelligence Index v4.3.2, September 2026)

Temperature is 0 for non-reasoning models and 0.6 for reasoning models unless the developer recommends otherwise. API failures are retried up to 30 times. pass@1 is aggregated across all repeats. Terminal-Bench 4.0 runs 66 tasks × 3 repeats with mini-swe-agent. The page describes intervals only for Elo-based evaluations (sandwich estimator). [Methodology](https://artificialanalysis.ai/methodology/intelligence-benchmarking)

### HELM

The original paper ran 3 random seeds for in-context example selection, citing cost. It used 1,000 evaluation instances per scenario and warned that some claims may therefore be statistically insignificant. Figure 31 shows the range across the three seeds. [HELM, arXiv 2211.09110v2 / TMLR 2023, §8 and Table 7](https://arxiv.org/abs/2211.09110)

HELM Capabilities (2025) downsamples scenarios to 1,000 instances and uses three LLM judges on WildBench to reduce variance; run counts are not stated. [HELM Capabilities](https://crfm.stanford.edu/2025/03/20/helm-capabilities.html)

### lm-evaluation-harness

Means use `sample_stddev / sqrt(n)` over items. Some non-mean metrics use a bootstrap (`bootstrap_iters` defaults to 100,000; 0 disables standard errors). [metrics.py](https://github.com/EleutherAI/lm-evaluation-harness/blob/d6de81643928d653435c431bae19945d41d32520/lm_eval/api/metrics.py), [evaluator.py](https://github.com/EleutherAI/lm-evaluation-harness/blob/d6de81643928d653435c431bae19945d41d32520/lm_eval/evaluator.py)

Tasks may set `repeats`, for example for self-consistency. `--seed` defaults to `0,1234,1234,1234` for Python, NumPy, Torch and few-shot sampling. [Task guide](https://github.com/EleutherAI/lm-evaluation-harness/blob/d6de81643928d653435c431bae19945d41d32520/docs/task_guide.md), [interface](https://github.com/EleutherAI/lm-evaluation-harness/blob/main/docs/interface.md)

### UK AISI Inspect (release 0.3.285, 25 October 2026)

Metrics normally run on the reduced per-sample scores, so the standard error is computed over samples rather than over all sample-epochs. `stderr(cluster=...)` gives clustered standard errors. `ci()` defaults to a Student-t interval (clusters − 1 degrees of freedom when clustered); `ci_wilson()` is recommended for binary scores. [Metrics](https://inspect.aisi.org.uk/metrics.html)

`--seed` is supported for OpenAI, Google, Groq, Mistral, Hugging Face and vLLM only. [Options](https://inspect.aisi.org.uk/options.html)

### HAL

The paper says high costs prevented multi-trial confidence intervals, so most evaluations rely on single runs. It also reports a provider swapping model weights behind an unchanged endpoint name. [HAL, arXiv 2510.11977v1, October 2025](https://arxiv.org/html/2510.11977)

## 4. What model developers report for agentic coding

These are developers' own launch posts and system cards, in date order:

| Date | Source | Reported method |
|---|---|---|
| Jan 2025 | DeepSeek-R1 | Greedy decoding increased repetition and variability across checkpoints, so pass@1 uses T = 0.6, top_p 0.95 and k = 4–64 samples per question by test-set size ([§3](https://arxiv.org/pdf/2501.12948v1)) |
| Aug 2025 | OpenAI GPT-5 system card | SWE-bench Verified on a fixed 477-task subset, averaging 4 tries per instance for pass@1. 95% intervals come from a bootstrap over attempts per problem ([§5.1.3.1, §5.1](https://cdn.openai.com/gpt-5-system-card.pdf)) |
| Sep 2025 | Anthropic, Claude Sonnet 4.5 | SWE-bench Verified averaged over 10 trials. Terminal-Bench averaged several runs on different days to smooth sensitivity to inference infrastructure ([launch post](https://www.anthropic.com/news/claude-sonnet-4-5)) |
| Oct 2025 | Anthropic, Claude Haiku 4.5 | SWE-bench Verified averaged over 50 trials with default sampling parameters. Terminal-Bench averaged 11 runs. Most other scores averaged 10 runs ([launch post](https://www.anthropic.com/news/claude-haiku-4-5)) |
| Nov 2025 | Anthropic, Claude Opus 4.5 | All evaluations averaged over 5 independent trials with default sampling settings ([launch post](https://www.anthropic.com/news/claude-opus-4-5)) |
| Dec 2025 | Google, Gemini 2.5 report v6 | Scores are pass@1 "single attempt" unless marked "multiple attempts". Smaller benchmarks average several trials (Aider Polyglot: 3). SWE-bench uses temperature 1, top_p 0.99, top_k 1024. Other providers' SWE-bench numbers are not directly comparable because scaffolds differ ([§3.1, Table 11](https://arxiv.org/pdf/2507.06261)) |
| Jul 2026 | Anthropic, Claude Opus 5 | Frontier-Bench reported as mean reward over 5 attempts per task ([launch post](https://www.anthropic.com/news/claude-opus-5)) |
| Sep 2026 | Anthropic, Claude Opus 5.5 | Terminal-Bench 4.0 reported with a standard error of ±2.6 points (±1.6–2 for other Claude models). The developer's setup reproduces the public 5-trial leaderboard figure within noise. Terminal-Bench-Science reports ±3.5–5 points ([launch post](https://www.anthropic.com/news/claude-opus-5-5)) |

The GPT-5 system card warns that its bootstrap captures only attempt sampling, not problem-level variance, and "can lead to overly tight confidence intervals" ([GPT-5 system card, §5.1](https://cdn.openai.com/gpt-5-system-card.pdf)). The same card attributes a difference between its 477-task result and the launch post's 74.9% to a verbosity setting ([§5.1.3.1](https://cdn.openai.com/gpt-5-system-card.pdf)). Newer OpenAI pages on openai.com returned HTTP 403 to this research and were not inspected.

**Inference:** Anthropic's ±2.6-point Terminal-Bench 4.0 figure is smaller than the case-sampling SE for a 66-task set at roughly 50% (about 6 points). That is consistent with a within-task calculation like the leaderboard's. Anthropic does not state its formula.

## 5. Sources of nondeterminism and whether they can be removed

### Temperature 0 is not deterministic in practice

- Aider observed different responses to identical OpenAI requests at temperature 0 (see §3).
- Atil et al. ran five LLMs configured to be deterministic over 10 runs on eight tasks. Accuracy varied by up to 15% between runs, the best-to-worst possible gap reached 70%, and identical output strings were rarer still. [arXiv 2408.04667v5](https://arxiv.org/abs/2408.04667)
- Yuan et al. found that batch size, GPU count and GPU type change greedy BF16 outputs. DeepSeek-R1-Distill-Qwen-7B varied by up to 9% in accuracy and 9,000 tokens in response length. Small early rounding differences can send reasoning chains apart. Their LayerCast remedy computes in FP32. [arXiv 2506.09501v2, October 2025](https://arxiv.org/abs/2506.09501)

### Batch invariance (Thinking Machines Lab, 10 September 2025)

The usual explanation, concurrency plus floating-point arithmetic, is incomplete. Typical forward passes are run-to-run deterministic for the same batch. The cause is that kernels such as RMSNorm, matrix multiplication and attention are not batch-invariant, and batch size depends on server load, which a user cannot see.

With default kernels, 1,000 temperature-0 completions of one prompt on Qwen3-235B produced 80 distinct outputs, first diverging at token 103. With batch-invariant kernels, all 1,000 were identical. The post reports a throughput cost; this note does not use or reproduce timing figures. [Defeating Nondeterminism in LLM Inference](https://thinkingmachines.ai/blog/defeating-nondeterminism-in-llm-inference/)

### Inference servers

- **vLLM** does not guarantee reproducibility by default, for performance. An online server can only become reproducible by enabling batch invariance. Reproducibility then holds only on the same hardware and vLLM version. [vLLM reproducibility](https://docs.vllm.ai/en/latest/usage/reproducibility.html)
- **llama.cpp server**: the request `seed` defaults to −1 (random). `cache_prompt` defaults to true; because logits are not guaranteed bit-for-bit identical across batch sizes on some backends, the docs say it can cause nondeterministic results. Continuous batching is on by default and slot count is automatic; the docs do not discuss determinism for those settings. [Server README at 63412d8](https://github.com/ggml-org/llama.cpp/blob/63412d8737b3efa30748dd79ceb2c93487e19f2b/tools/server/README.md)
- **Strata v0.2.2**: the server forwards a positive integer request `seed` to its engine and can run concurrent requests in batch slots ([server.py at 011c9e6, lines 934–941 and 1401–1403](https://github.com/Niko1221/Strata/blob/011c9e600a93bbc9fd451c563501b5831c32bbca/serve/server.py#L1401)). This research found no statement about batch invariance in the inspected source.

**Inference:** under Thinking Machines' mechanism, prompt caching and concurrent requests on a shared local server can change numerics even with a fixed seed. A fixed seed fixes the random draws, not the logits they are drawn from.

### Hosted APIs

- **OpenAI.** In the current API specification, Chat Completions `seed` is beta and marked deprecated. It is described as best effort, with determinism not guaranteed and `system_fingerprint` exposed to monitor backend changes. The Responses API request schema has no `seed` field. [openai-openapi at 8243cc8, 24 October 2026](https://github.com/openai/openai-openapi/blob/8243cc8fa6f04430fb1f1a6a2cb926fbeb4f7f26/openapi.yaml)
- **Anthropic.** API version 2026-10-21 returns a 400 error when `temperature`, `top_p` or `top_k` is sent. Requests sample with defaults, including temperature 1.0. Claude 4.7 and later models already accepted only the defaults. [Migration to 2026-10-21](https://platform.claude.com/docs/en/api/migration-2026-10-21.md)
- The Opus 5.5 migration guide adds that temperature 0 never guaranteed identical outputs on earlier models ([guide](https://platform.claude.com/docs/en/models/opus-5-5/migration-guide.md)). The Messages create reference has no `seed` parameter ([reference](https://platform.claude.com/docs/en/api/messages/create.md)).

### Infrastructure and environment

Anthropic varied resource configurations on Terminal-Bench 2.0 with the same model, harness and tasks. The most- and least-resourced setups differed by 6 points (p < 0.01). Infrastructure error rates fell from 5.8% at the specified limits to 0.5% uncapped. Between 1× and 3×, scores stayed within noise, but beyond about 3× extra resources changed what the benchmark measured. On SWE-bench (227 problems × 10 samples), 5× RAM gave 1.54 points over 1×. Pass rates appeared to vary by time of day, though this was not formally measured.

The post recommends treating resources as a controlled, published variable, running at several times and days, and treating leaderboard gaps under about 3 points skeptically until setups match. [Quantifying infrastructure noise in agentic coding evals, 5 February 2026](https://www.anthropic.com/engineering/infrastructure-noise)

Terminal-Bench 4.0 calibrated its resources using this method ([announcement](https://www.tbench.ai/news/terminal-bench-4-0)). HAL reports endpoints whose weights changed without notice ([HAL](https://arxiv.org/html/2510.11977)).

### Summary of what can be removed

| Source | Removable? | Evidence |
|---|---|---|
| Sampling randomness, local server | Fixed by a seed for a given request | llama.cpp, vLLM, Strata docs and source above |
| Numerics from batching and caching, local server | Only with batch-invariant kernels on fixed hardware and software | Thinking Machines; vLLM |
| Sampling randomness, OpenAI Responses or Claude | Not controllable: no seed; Claude temperature fixed at 1.0 | OpenAI spec; Anthropic migration guide |
| Provider infrastructure and weights | Not controllable by the evaluator; can be recorded | Anthropic infrastructure post; HAL |
| Within-case variability as a property of the model | Not removable without changing what is measured | Miller §3.3 (do not lower temperature to reduce variance) |

**Inference:** a fully reproducible run at one seed is still one draw from the model's distribution of trajectories. Reproducibility makes a rerun repeat a result; it does not make that result a better estimate of the model's per-case success rate.

## 6. Small-benchmark arithmetic

All numbers here were computed for this note. Formulas: binary SE `sqrt(p(1−p)/n)` ([Miller Eq. 2](https://arxiv.org/html/2411.00640)); variance decomposition and minimum detectable effect ([Miller §3 and Eq. 10](https://arxiv.org/html/2411.00640)); Wilson intervals ([NIST e-Handbook 7.2.4.1](https://www.itl.nist.gov/div898/handbook/prc/section2/prc241.htm)); exact paired test on discordant cases ([McNemar 1947](https://doi.org/10.1007/BF02295996)). z values: 1.96 for two-sided α = 0.05 and 0.84 for 80% power; their sum is 2.80.

### 6.1 One attempt per case: uncertainty from which cases were chosen

| n | One case moves the score by | SE at p = 0.5 | 95% half-width at p = 0.5 | SE at p = 0.8 | 95% half-width at p = 0.8 |
|---:|---:|---:|---:|---:|---:|
| 11 | 9.09 pp | 15.1 pp | ±29.5 pp | 12.1 pp | ±23.6 pp |
| 50 | 2.00 pp | 7.07 pp | ±13.9 pp | 5.66 pp | ±11.1 pp |
| 100 | 1.00 pp | 5.00 pp | ±9.8 pp | 4.00 pp | ±7.8 pp |
| 500 | 0.20 pp | 2.24 pp | ±4.4 pp | 1.79 pp | ±3.5 pp |

NIST notes that normal approximations may be inaccurate for very small samples. Wilson 95% intervals: 6/11 → 28.0–78.7%; 9/11 → 52.3–94.9%; 250/500 → 45.6–54.4%; 400/500 → 76.3–83.3%. The repository's [task-quality note](task-quality-and-verification.md) already gives a 12-case Wilson example and cautions that hand-picked, correlated cases do not justify generalizing to "all Elixir work."

### 6.2 What repeating each case K times reduces

Let case i have success probability pᵢ under fixed settings. One attempt's variance splits into a between-case term `Var(pᵢ)` and a within-case term `E[pᵢ(1−pᵢ)]`. With K attempts per case and n cases, the variance of the mean is `(Var(pᵢ) + E[pᵢ(1−pᵢ)]/K) / n` (Miller §3). Only the second term shrinks with K.

The table uses Miller's uniform-difficulty example: between-case 1/12, within-case 1/6, mean 0.5.

| K attempts per case | SE, n = 11 | SE, n = 500 | Extra attempts per model, n = 11 | Extra attempts per model, n = 500 |
|---:|---:|---:|---:|---:|
| 1 | 15.1 pp | 2.24 pp | 0 | 0 |
| 2 | 12.3 pp | 1.83 pp | 11 | 500 |
| 3 | 11.2 pp | 1.67 pp | 22 | 1,000 |
| 5 | 10.3 pp | 1.53 pp | 44 | 2,000 |
| 10 | 9.5 pp | 1.41 pp | 99 | 4,500 |
| unlimited | 8.7 pp | 1.29 pp | — | — |

The floor (8.7 pp at n = 11, 1.29 pp at n = 500) is the between-case part that only more cases can reduce.

**Run-to-run spread on a fixed release.** If the question is "how much will this model's score on these exact cases move if I rerun it?", only the within-case term applies. The standard deviation of one run's score is `sqrt(Σ pᵢ(1−pᵢ)) / n`, and the difference between two independent runs has √2 times that. This is the quantity the Terminal-Bench leaderboard interval estimates (§3). Illustrative 11-case scenarios:

| 11 cases | SD of one run's score | SD of the difference between two runs |
|---|---:|---:|
| every case at pᵢ = 0.5 | 15.1 pp | 21.3 pp |
| every case at pᵢ = 0.8 | 12.1 pp | 17.1 pp |
| 5 always pass, 3 always fail, 3 at 0.5 | 7.9 pp | 11.1 pp |
| 5 always pass, 3 always fail, 3 at 0.8 | 6.3 pp | 8.9 pp |
| 500 cases, every case at 0.5 (for comparison) | 2.24 pp | 3.16 pp |

**Inference:** observed run-to-run jitter on this benchmark is determined by how many cases are genuinely uncertain for a given model. Cases that a model always passes or always fails add no jitter and gain nothing from repeats. Per-case pass counts across repeats would show which cases those are.

### 6.3 Smallest difference two models can be shown to differ by

Using Miller's Eq. 10 with α = 0.05 two-sided and 80% power, both models at success rate p and single attempts, the per-case difference variance is `2p(1−p)(1−ρ)`. Here ρ is the correlation of the two models' per-case outcomes. This is an algebraic consequence of Miller's correlation form in §4.2. ρ = 0 equals an unpaired comparison; ρ = 0.5 is Miller's illustrative value, not a measurement for this benchmark.

| Paired, one attempt per case | n = 11 | n = 50 | n = 100 | n = 500 |
|---|---:|---:|---:|---:|
| p = 0.5, ρ = 0 | 59.7 pp | 28.0 pp | 19.8 pp | 8.9 pp |
| p = 0.5, ρ = 0.5 | 42.2 pp | 19.8 pp | 14.0 pp | 6.3 pp |
| p = 0.8, ρ = 0 | 47.8 pp | 22.4 pp | 15.8 pp | 7.1 pp |
| p = 0.8, ρ = 0.5 | 33.8 pp | 15.8 pp | 11.2 pp | 5.0 pp |

The next table adds repeats, using Miller's example parameters (ω² = 1/9; within-case variance 1/6 per model). At n = 198 it reproduces his 13.2% → 7.5% result within rounding.

| K attempts per case, both models | n = 11 | n = 50 | n = 100 | n = 500 |
|---:|---:|---:|---:|---:|
| 1 | 56.3 pp | 26.4 pp | 18.7 pp | 8.4 pp |
| 3 | 39.8 pp | 18.7 pp | 13.2 pp | 5.9 pp |
| 5 | 35.6 pp | 16.7 pp | 11.8 pp | 5.3 pp |
| 10 | 32.1 pp | 15.1 pp | 10.6 pp | 4.8 pp |
| unlimited | 28.2 pp | 13.2 pp | 9.3 pp | 4.2 pp |

With the same parameters, detecting a 3-point difference needs about 3,880 cases at K = 1, or 969 with no within-case variance. The second figure is Miller's.

**Exact test at n = 11.** For paired binary outcomes, only discordant cases (one model passes, the other fails) carry information (McNemar). The exact two-sided p-value when all d discordant cases favor one model is 2·0.5^d. d = 5 gives 0.0625 and d = 6 gives 0.031. So on 11 cases, a single-attempt difference is significant at the 5% level only with at least 6 discordant cases all in one direction (≥ 54.5 pp). A 6–1 split of 7 discordant cases gives p = 0.125. The normal-approximation tables above are rough at this size.

## 7. Where sources disagree, and surprises

1. **What a "±" covers differs.**
   - Miller, lm-eval and Epoch include case sampling.
   - METR's bootstrap includes tasks and runs.
   - The GPT-5 system card bootstraps attempts only and says so.
   - Terminal-Bench 4.0's leaderboard formula includes within-task variation only. **Inference from the formula:** more trials per task narrow its interval toward zero although the task set stays the same size.

   The intervals are not interchangeable. ([Miller](https://arxiv.org/html/2411.00640), [METR](https://arxiv.org/html/2503.14499), [GPT-5 card](https://cdn.openai.com/gpt-5-system-card.pdf), [Terminal-Bench metrics.py](https://github.com/harbor-framework/terminal-bench/blob/e67a2cb7db4d9795c212909b3395d8c22ad60aec/leaderboard/src/leaderboard/core/metrics.py))
2. **Temperature advice conflicts.**
   - Miller says not to change temperature to reduce score variance.
   - Artificial Analysis uses temperature 0 for non-reasoning models.
   - Chen et al. and LiveCodeBench use 0.2 for pass@1.
   - DeepSeek-R1 avoided greedy decoding because it increased variability.
   - Gemini used temperature 1 on SWE-bench.
   - Anthropic's API no longer accepts any temperature.

   The goals differ (comparability, reproducibility, representative behavior), so these are different choices rather than a single disputed fact.
3. **SWE-bench's Best@1 wording vs developer reporting.** The checklist defines multi-run Best@1 as instances solved in *every* run, a pass^k-like count. Developers report SWE-bench Verified as averages over 4 to 50 trials. **Inference:** for the same runs, the every-run count is never higher than the average. ([Checklist](https://github.com/SWE-bench/experiments/blob/40f164d5b8f1d249bf95a6df8b74b577fd8e519d/checklist.md), §4)
4. **Required repeats vary with cost.** Terminal-Bench requires at least five trials and Artificial Analysis uses three on the same benchmark. Anthropic has published 5, 10 and 50 trials; METR uses about 8. SWE-bench submissions are single predictions per instance, and HAL mostly uses single runs because of cost.
5. **Benchmark size.** Miller suggests at least 1,000 questions for 3-point sensitivity. Signal and Noise finds larger is not necessarily better for its checkpoint-noise measure. The two papers measure different kinds of noise.
6. **"Seed" means different things.** It fixes sampling in llama.cpp, vLLM and Strata, and is best effort and deprecated in OpenAI Chat Completions. It is absent from OpenAI Responses and Claude. Even locally, a seed does not remove batch or caching numerics (§5).
7. **Infrastructure noise can match model gaps.** Anthropic measured a 6-point Terminal-Bench 2.0 swing from resource configuration alone.

## 8. Relevant facts about this benchmark

- Committed definitions (HEAD `aae5791d`): a run is one model profile through one harness with the seed that harness supports. A published result represents one run, not an aggregate of repeated runs. Each run has one attempt per case, and scores weight cases equally. Local servers default to seed 101; subscription runs record no seed. Comparison requires identical effective policies. [CONTEXT.md](../../CONTEXT.md), [evaluation](../evaluation.md)
- During this research the working tree gained an uncommitted CONTEXT.md edit. It defines a **run series**: up to three runs with identical settings, differing only in seed where supported. The published score would be the mean of the runs completed so far, together with the number of runs and per-case pass counts. This note reflects the file as observed; it is not a decision record. [CONTEXT.md working tree](../../CONTEXT.md)
- The local gateway removes Pi's `temperature`, `top_p` and `top_k`, so server defaults apply, and sends the configured seed on every model call ([pi_gateway.ex:111–124](../../lib/eab/pi_gateway.ex), [default seed](../../lib/eab_web/dashboard_live.ex)). It does not set llama.cpp's `cache_prompt`. **Inference:** the documented default (true) applies. The controller never starts or changes the model server ([runbook](../runbook.md)), so slot, batching and caching settings belong to the server operator.
- Subscription Claude runs through Claude Code with no seed ([ADR 0010](../adr/0010-run-subscription-claude-through-claude-code-harness.md), [evaluation](../evaluation.md)). Anthropic's current API samples at temperature 1.0 (§5).
- ADR 0008 targets about 500 cases per model ([ADR 0008](../adr/0008-resume-completed-case-checkpoints.md)). This machine must not be used for speed measurements ([AGENTS.md](../../AGENTS.md)). That limits evaluating the throughput cost of deterministic serving locally.

## Options for this benchmark

These options are supported by the sources above. They are listed neutrally and can be combined. Extra attempts are per model per release, relative to today's one attempt per case.

| Option | What it changes | Extra attempts (n = 11 / n = 500) | Trade-offs | Precedent |
|---|---|---|---|---|
| A. Keep one run; publish a case-sampling interval and per-case outcomes | Adds Wilson or SE to the existing score | 0 / 0 | ±24–30 pp at n = 11 and ±3.5–4.4 pp at 500. Cannot separate rerun noise from case selection. | Miller §2; lm-eval; Inspect `ci_wilson`; NIST |
| B. Paired comparison rule | Compare models per case on the same release and harness, and call differences below the detectable size indistinguishable | 0 / 0 | At n = 11, significance needs ≥ 6 one-way discordant cases. Depends on unknown between-model correlation. | Miller §4–5; McNemar |
| C. K attempts per case, or a three-run series (K = 3) | Score becomes the mean per-case pass rate with case-clustered SE and per-case pass counts | K = 3: 22 / 1,000; K = 5: 44 / 2,000 | Shrinks only within-case variance (n = 11 floor about 8.7 pp). Changes the published-result definition and resume semantics. Multiplies subscription usage. Partial series give different precision. | Terminal-Bench ≥ 5; Anthropic 5–50; OpenAI 4; METR ~8; LiveCodeBench 10; Epoch 8–16; Artificial Analysis 3–5; Gemini 3 |
| D. Reliability metrics from the same repeats | Also publish pass^k and unbiased pass@k per case | Same as C | Answers consistency or ceiling, not average skill. pass^k needs K ≥ k and is harsh for small K. More numbers to explain. | τ-bench; Artificial Analysis AnalystAgent; Inspect reducers; Terminal-Bench pass@2–5 |
| E. More cases (planned ~500) | Shrinks between-case variance, the only lever for it | n attempts per run; curation cost | At n = 500, one attempt detects about 6–9 pp paired differences at p = 0.5 (§6.3). Size alone is not sufficient per Signal and Noise. | Miller (≥ 1,000 suggestion); ADR 0008 target |
| F. More repeatable local inference | Fix and record seed (already), slot count, prompt caching, or batch-invariant serving on fixed hardware and software | 0 / 0 | Local servers only. Subscription APIs have no seed. Throughput cost cannot be measured on this machine. A reproducible run is still one draw. With fully deterministic serving, repeats need different seeds to sample variation (inference). | Thinking Machines; vLLM; llama.cpp; Miller §3.3 |
| G. Infrastructure as recorded, controlled variables | Record resource limits, timeouts and serving configuration in run identity, and hold them equal across compared runs | 0 / 0 | Removes a confound (up to 6 pp on Terminal-Bench 2.0) but not sampling noise. | Anthropic infrastructure post; Terminal-Bench 4.0 |
