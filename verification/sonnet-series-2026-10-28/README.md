# Sonnet 5.5 series, 2026-10-28

Scored runs of Sonnet 5.5 at max effort through the [Claude Code harness](../../docs/adr/0010-run-subscription-claude-through-claude-code-harness.md), on the frozen release that [Opus 5.5 validated](../opus-validation-2026-10-26/README.md), with the same kit and 2 parallel attempts. They are published as one [run series](../../docs/adr/0011-publish-three-run-series.md).

| Run | Outcome |
| --- | --- |
| `20261028-065746-940e9ba4` | **18 of 20 passed.** ash-pr-3031 and guardian-pr-748 failed. Evidence in [`run-20261028-065746-940e9ba4/`](run-20261028-065746-940e9ba4/). |
| `20261028-133546-8d515727` | **18 of 20 passed.** The same two failed. Evidence in [`run-20261028-133546-8d515727/`](run-20261028-133546-8d515727/). |

Each run folder holds a grade summary and the sealed patch per case, plus the hook decision log. Each failure's folder also holds the patch that shows what separated it from a pass. Each case's `logs/` folder holds the attempt's full logs: the controller's `activity.log`, the solver's `claude-transcript.jsonl` and the grader's `grade.json`. The user's email address and Claude organization ID are replaced with `[redacted email]` and `[redacted organization]`; nothing else is changed.

## How the runs were checked

Independent reviewers read all 40 attempts against the ticket, requirement texts, reference, hidden tests and each attempt's logs. Each claim that mattered was run before it was accepted.

- **All 36 passes are genuine.** No solution deleted or weakened an existing test, special-cased hidden data, used a tooling hack or kept an edit outside its case's allowed paths. In every case both runs reached the same design and the same outcome.
- **ash-pr-3031 failed both runs on a stated requirement** (13 of 15 hidden checks pass). When an expression argument is present, Sonnet wrapped the already cast literal in a typed value without marking it as cast, so it was cast a second time: the custom `Label` type then rejects its own output, and `NormalizedInteger` changes value. This is the requirement Opus also missed. With the value marked as cast, each Sonnet patch passes all 15 ([run 1](run-20261028-065746-940e9ba4/ash-pr-3031/soundness/), [run 2](run-20261028-133546-8d515727/ash-pr-3031/soundness/)).
- **guardian-pr-748 failed both runs before any test ran** (`disallowed_or_oversized_patch`).
  - **Cause:** each patch also added a section to `README.md`. The instructions list "Allowed edit prefixes: lib/, test/, guides/, CHANGELOG.md, mix.exs", and the grader rejects a patch that modifies a file outside them.
  - **The rest of each patch is correct.** Without `README.md`, each passes all 23 hidden checks and all 155 preservation tests ([run 1](run-20261028-065746-940e9ba4/guardian-pr-748/soundness/), [run 2](run-20261028-133546-8d515727/guardian-pr-748/soundness/)).
  - **Why it counts as the model's miss:**
    - the limit is stated in every attempt's instructions;
    - Sonnet reverted its own out-of-bounds edits in absinthe-pr-1176 and ash-pr-3031;
    - all seven Opus attempts documented the feature only in `guides/` and `CHANGELOG.md`, one of them declining `README.md` because it is outside the allowed prefixes.
  - **The other side:** the ticket says "Documentation updates are welcome but optional" without naming where, `README.md` is guardian's main documentation of `:secret`, and the grader rejects the whole patch for one optional prose section.
  - **Decision:** recorded, not changed. Changing the case would change the release under every published series.
- **Harness and environment:**
  - **Tool calls:** none lost its answer. Three calls ended when the solver's own command timeout fired on a hung scratch test, and each returned its output.
  - **Infrastructure:** no database connection dropped, and no attempt errored.
  - **Models:** every attempt resolved to `claude-sonnet-5-5` at `max`, with no safety stops.
  - **Access:** no solver reached the reference, the hidden tests, upstream history or the network. Solvers sometimes called a `bash` tool that does not exist; Claude Code refused each such call, so nothing ran on the host.
- **Over the declared budget:** 9 of the 40 attempts generated more than the declared 262,144 output tokens (4 in run 1, 5 in run 2; 7 of them passed). Claude Code cannot enforce that budget, so it is flagged, not failed ([ADR 0010](../../docs/adr/0010-run-subscription-claude-through-claude-code-harness.md)). None of Opus's three series runs went over it.

## Recorded, not acted on

- **Gaps no check catches,** each in one attempt, none contradicting a check:
  - pinchflat-pr-610 run 2 replaces invalid UTF-8 in the stored reason;
  - pinchflat-pr-610 run 1 links only lowercase `http(s)://` values;
  - beacon-pr-687 run 2 takes the mount path from the first configured site;
  - vutuv-pr-1759 run 2 keeps whitespace-only name parts.
- **Environment notes, outside every graded command:**
  - `LivebookWeb.SessionLiveTest` is flaky on the starting source too (2 of 40 runs);
  - vutuv's `BuildInfoTest` and `LayoutHTMLTest` fail in a full suite run when `BuildInfo.commit_sha` is nil at compile time;
  - the non-executable `/tmp` stops a NIF loading from a scratch copy in pinchflat.
