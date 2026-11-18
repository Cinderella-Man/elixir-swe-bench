# Elixir Agent Benchmark

## Language

**Case**: A defined coding task with an exact starting project revision, a task description and executable acceptance criteria. Every case comes from an actual upstream PR and identifies whether it concerns a bug fix, feature or refactor.

**Candidate case**: A proposed coding task being inspected and qualified before admission to a benchmark release. Discovery of a merged PR alone does not make it an admitted case.

**Benchmark release**: A frozen, versioned selection of qualified case definitions used for comparable model evaluations.

**Feature spec**: The solver's ticket for a feature case. It records the decisions a clarifying interview would settle: behaviour, edge cases, scope, non-goals and the public interface, with no implementation recipe.
_Avoid_: grilled ticket, requirements brief, minimal ticket

**Curator extension**: Implementation and checks a curator adds beyond an upstream PR to make a coherent feature case, or to correct a reference that fails a requirement its ticket states. Provenance records it separately from the upstream change.
_Avoid_: enrichment, synthetic PR

**Reference solution**: An accepted upstream implementation used to qualify a case's checks. Submissions may use another implementation that satisfies the stated contract.

**Reference repair**: A reference solution for a bug-fix case; also the historical name used by the original repair-only inventory.

**Model profile**: The served model, quantization, context capacity and serving configuration reported by an endpoint. Missing metadata remains unknown; aliases do not establish exact artifact identity.

**Model identity**: The artifact name and quantization recovered from reported model metadata, the quantization's maker when the served file names one, and the sha256 of the served weight files when the collector hashed them, kept separately from the API routing alias used to send requests. Two makers' identically named files are different models, and so are two uploads of one name.

**Model file source**: Where the served weight files came from, as the operator declares it before a local run: the file's URL, parsed into Hugging Face author, repository, revision and path, and an optional release label such as "v3.1". A Hugging Face source is looked up for its commit and shard hashes, and is verified when the hashes measured on the model host match an upload in that repository's history. A declaration alone is unverified.
_Avoid_: model source (the dashboard's choice of local server, ChatGPT or Claude Code), model card

**Model weight size**: The recorded size of the model's weight files in bytes, displayed in decimal GB. It excludes context and runtime memory and is not a total VRAM requirement.

**Deployment memory observation**: A dated sample of an identified inference process's GPU allocation, RAM and serving configuration. Process/service lifetime peaks do not establish the peak during a particular benchmark run or the minimum hardware required.

**Attempt measurement**: A Pi attempt's elapsed time from startup through completion, with its **model speed**: the prompt tokens processed and tokens generated per second, summed over its model calls. llama.cpp reports its own timings; the controller times Strata's streamed tokens, network included. Both are recorded only when parallel attempts is 1, for a model served on another machine. Generated-token accounting remains available without timing. A published run states its own case times and model speed; they are never averaged across a run series or scored.

**Run**: An evaluation of one model profile through one harness across a frozen selection of cases, using fixed inputs and the budgets and seed that harness supports.

**Run series**: Up to three runs of one model artifact and quantization through one harness on one benchmark release, with the same server type, chat template, sampling defaults and effective settings apart from seed. Runs differ in seed where the endpoint supports seeds and may come from different people, machines, server builds and benchmark code versions. Its score is the mean of its runs' final scores; it is complete once three runs have final scores.
_Avoid_: repeats, trial set, epochs

**Published result**: Outcomes for the current admitted cases from one run series, with matching case fixture hashes, model identity, harness and recorded evaluation conditions. Rejected cases are omitted. Each published result is one run series, not a single run: its score is the mean of the runs it has so far, it states how many of the three required runs that is, and each case shows how many of those runs passed. Rows may have different effective settings. Each run also states the case times and model speed it recorded, which belong to that run alone.

**Run logs**: The record of what happened in a run, kept in the repository beside its published result: for every attempt the instructions the agent was given, its whole conversation, the controller's log, the grader's output and the submitted patch, and for the run the tokens of every model call. Account identifiers and machine names are replaced.
_Avoid_: evidence dump, artifacts

**Machine**: Where a run's model was served: the model host's GPUs with their memory, CPU, system RAM, the model server and its build, the KV cache type and the server's speed-related flags. Runs of one run series may use different machines; each published run states its own.
_Avoid_: hardware profile, rig

**Speed cases**: A few current cases of a benchmark release on which model speed is compared, ranging from short to long conversations. A model generates more slowly as its conversation grows, so only measurements on the same cases compare.

**Speed run**: A run of only the speed cases, one at a time, on a model served by llama.cpp or Strata, published for its case times, model speed and machine. It is never scored and joins no run series, so any quantization or machine of a model can be measured. A full run timed on every speed case also counts as a speed measurement.
_Avoid_: speed benchmark, speed series

**Attempt**: One agent's investigation, edits, tool calls and submission for a case. A run records one scored attempt per case and retains interrupted work separately.

**Parallel attempts**: The most attempts one run works on at the same time. It is a run setting, 1 by default; runs of one run series may use different values. Elapsed attempt time is recorded only when it is 1.

**Workspace**: A fresh offline Docker environment containing a case's starting project source and prepared dependencies. It excludes reference solutions, grader-only checks, upstream Git history and controller credentials.

**Prepared case**: A case whose starting environment is available and whose fixture qualification is valid for that environment.

**Offline-ready case**: A prepared case that also has its source check, its image with Pi attached and a matching qualification receipt, so a run can use it with no internet.

**Case baseline**: The reusable pristine starting state of a case, including prepared source, dependencies and initial service data. It excludes changes and observations produced by attempts or grading checks.

**Build seed**: A pristine preparation build whose compatible artifacts can be reused when preparing another case. It contains no agent investigation, reference repair or grading state.

**Database seed**: Pristine initialized database state whose compatible migration history can be reused when preparing another case. It contains no changes made by an attempt or grading check.

**Waiting workspace**: A pristine workspace held ready for a coming attempt, before the agent's investigation begins. Attempts start in case order and may finish in any order.

**Submission**: The saved patch produced by an attempt and handed to the grader. It holds what the attempt changed inside the case's edit area.

**Edit area**: The path prefixes a case allows a solver to change. Changes outside it are discarded before grading.

**Context budget**: The maximum combined input and response space for one model interaction, including a small safety allowance.

**Peak context**: The largest conversation any model call of an attempt held: the prompt that call was sent plus the reply it generated. History is never compacted, so it is the context the attempt needed.
_Avoid_: context used, context usage, total tokens

**Context size**: A number of context tokens at which a published result can be read, from 65,536 to 262,144. At a size a case counts only if the agent finished on its own, the attempt's peak context is within the size and its patch passes. It is read from a run as it was made; no run is made at a size.
_Avoid_: context cap, context limit (a run's own limit is its context budget)

**Token allowance**: The most tokens an attempt at one case may generate, including reasoning and tool syntax, in a benchmark release that sets one per case. It is twice the median the validator model generated on that case, with a floor, and the agent is told it. An attempt must finish inside it to pass. No release sets one: context size is the benchmark's measure of economy.
_Avoid_: token cap, per-case budget, time limit

**Generation budget**: The most tokens an attempt may generate in total, including reasoning and tool syntax. In a release with token allowances it is the case's allowance. Otherwise hosted models have one for the whole run, as a threshold checked between replies, and local attempts have none since 2026-11-13: only the context budget limits them.

**Response budget**: The most tokens one model reply may generate. Only local series made before 2026-11-13 have one; since then a local reply is limited only by the context budget.

**Cutoff**: The budget that ended an attempt before the agent finished: context, generation where a run has that budget or, in older local series, response. The patch at that point is graded. Without token allowances a cut-off attempt may still pass; with them it fails, and its patch's verdict is kept beside the case outcome.

**Harness**: The coding-agent program, tool set and fixed instructions through which a model makes attempts. Pi and Claude Code are harnesses. Each run uses one harness; comparing runs across harnesses confounds the model with the harness.

**Agent**: The pinned harness instance working on one attempt. A Pi agent runs inside the case workspace; a Claude Code agent works from outside it through tools confined to that workspace. The agent owns the model conversation; Elixir provides the workspace and grades its changes.

**Model transport**: The restricted connection between a Pi agent and the configured model, enforcing budgets and accounting while keeping endpoint credentials outside the workspace.

**Grader**: The independent executable checks applied to a submission in fresh workspaces.

**Grader-only check**: An acceptance check withheld from the attempt workspace. Its source is public in this repository.

**Fixture qualification**: Controls proving that the current environment and grader reject unchanged starting code, plausible incomplete solutions and integrity bypasses, while accepting the reference solution.

**Prompt sufficiency review**: Review that each scored obligation follows from the task description and project information available to the solver. A private grading preference is not a task requirement.

**Solvability validation**: Evidence that a model can complete a case using only solver-visible information under recorded conditions. This complements fixture qualification and prompt sufficiency review without certifying exhaustive correctness.

**Validation run**: A run of the validator model whose outcomes decide which cases stay in a release. It is never published or scored, because its passes are what kept the cases.

**Case outcome**: A completed pass or fail. The grader's verdict on the patch decides it, and in a release with token allowances a pass also needs the agent to have finished on its own inside the case's allowance. Infrastructure and accounting errors remain errors.

**Score**: The percentage of selected cases passed, with equal case weight. A published result also has a score at each context size, counting only the cases that count at that size. A final score requires a valid outcome for every selected case; missing, errored, cancelled and interrupted attempts prevent a final score.
