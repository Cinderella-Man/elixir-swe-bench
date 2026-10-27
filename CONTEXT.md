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

**Model identity**: The artifact name and quantization recovered from reported model metadata, kept separately from the API routing alias used to send requests.

**Model weight size**: The recorded size of the model's weight files in bytes, displayed in decimal GB. It excludes context and runtime memory and is not a total VRAM requirement.

**Deployment memory observation**: A dated sample of an identified inference process's GPU allocation, RAM and serving configuration. Process/service lifetime peaks do not establish the peak during a particular benchmark run or the minimum hardware required.

**Attempt measurement**: Opt-in elapsed attempt time and model-request time from a named, explicitly authorized performance environment. Generated-token accounting remains available without timing. Model-request throughput includes prompt processing and response transfer.

**Run**: An evaluation of one model profile through one harness across a frozen selection of cases, using fixed inputs and the budgets and seed that harness supports.

**Run series**: Up to three runs of one model artifact and quantization through one harness on one benchmark release, with the same server type, chat template, sampling defaults and effective settings apart from seed. Runs differ in seed where the endpoint supports seeds and may come from different people, machines, server builds and benchmark code versions. Its score is the mean of its runs' final scores; it is complete once three runs have final scores.
_Avoid_: repeats, trial set, epochs

**Published result**: Outcomes for the current admitted cases from one run series, with matching case fixture hashes, model identity, harness and recorded evaluation conditions. Rejected cases are omitted. Each published result is one run series, not a single run: its score is the mean of the runs it has so far, it states how many of the three required runs that is, and each case shows how many of those runs passed. Rows may have different effective settings.

**Attempt**: One agent's investigation, edits, tool calls and submission for a case. A run records one scored attempt per case and retains interrupted work separately.

**Parallel attempts**: The most attempts one run works on at the same time. It is a run setting, 1 by default; runs of one run series may use different values. Elapsed attempt time is recorded only when it is 1.

**Workspace**: A fresh offline Docker environment containing a case's starting project source and prepared dependencies. It excludes reference solutions, grader-only checks, upstream Git history and controller credentials.

**Prepared case**: A case whose starting environment is available and whose fixture qualification is valid for that environment.

**Case baseline**: The reusable pristine starting state of a case, including prepared source, dependencies and initial service data. It excludes changes and observations produced by attempts or grading checks.

**Build seed**: A pristine preparation build whose compatible artifacts can be reused when preparing another case. It contains no agent investigation, reference repair or grading state.

**Database seed**: Pristine initialized database state whose compatible migration history can be reused when preparing another case. It contains no changes made by an attempt or grading check.

**Waiting workspace**: A pristine workspace held ready for a coming attempt, before the agent's investigation begins. Attempts start in case order and may finish in any order.

**Submission**: The saved patch produced by an attempt and handed to the grader.

**Context budget**: The maximum combined input and response space for one model interaction, including a small safety allowance.

**Generation budget**: The cumulative tokens generated during an attempt, including reasoning and tool syntax.

**Harness**: The coding-agent program, tool set and fixed instructions through which a model makes attempts. Pi and Claude Code are harnesses. Each run uses one harness; comparing runs across harnesses confounds the model with the harness.

**Agent**: The pinned harness instance working on one attempt. A Pi agent runs inside the case workspace; a Claude Code agent works from outside it through tools confined to that workspace. The agent owns the model conversation; Elixir provides the workspace and grades its changes.

**Model transport**: The restricted connection between a Pi agent and the configured model, enforcing budgets and accounting while keeping endpoint credentials outside the workspace.

**Grader**: The independent executable checks applied to a submission in fresh workspaces.

**Grader-only check**: An acceptance check withheld from the attempt workspace. Its source is public in this repository.

**Fixture qualification**: Controls proving that the current environment and grader reject unchanged starting code, plausible incomplete solutions and integrity bypasses, while accepting the reference solution.

**Prompt sufficiency review**: Review that each scored obligation follows from the task description and project information available to the solver. A private grading preference is not a task requirement.

**Solvability validation**: Evidence that a model can complete a case using only solver-visible information under recorded conditions. This complements fixture qualification and prompt sufficiency review without certifying exhaustive correctness.

**Validation run**: A run of the validator model whose outcomes decide which cases stay in a release. It is never published or scored, because its passes are what kept the cases.

**Case outcome**: A completed pass or fail from the grader. Infrastructure and accounting errors remain errors.

**Score**: The percentage of selected cases passed, with equal case weight. A final score requires a valid outcome for every selected case; missing, errored, cancelled and interrupted attempts prevent a final score.
