# Final case fixes after the fourth Opus validation run, 2026-10-27

Reviews of [Opus validation run `20261027-143532-8d2e4ed2`](../opus-validation-2026-10-26/README.md) (run E) read each of its 19 passing patches against its ticket, requirements, reference and hidden tests, and read each attempt's logs. Every pass was genuine. 12 cases were accepted as they are. In 8, a wrong solution the reviewers built passed every hidden test, or a text promised more than the reference does. Every claim was run before anything changed. The user made this the final strengthening batch ([ADR 0012 amendment](../../docs/adr/0012-rebuild-release-and-validate-with-unpublished-opus-runs.md)).

## How each change was proven

The same method as [the third batch](../case-fixes-2026-10-27-run-d/README.md). Each change ran in throwaway containers built from the case's prepared image, mirroring the grader's hidden stage, against:

- the reference;
- Opus's patch from run E;
- the untouched starting source, which must fail exactly the listed starting failures in test bodies;
- the case's partial-fix control, which must still fail;
- one or more **wrong solutions** the change targets, each passing the released checks and failing the new ones (kept per case under `wrong-fixes/`);
- every wrong solution kept by the earlier batches for the case, which must still fail.

Checks involving processes or browsers ran at least three times on the reference. Independent reviewers approved every changed bundle against its exact file hashes (`independent-review.json`). Two drafts were first rejected and revised:

- **pinchflat-pr-610:** a released test named for long, reserved-character messages had been widened with a newline-ending message. The new input now has its own test.
- **livebeats-pr-37:** the new resume step could race the next click, which another LiveView handles; it now waits for the server's reply.

Finally each case passed three fresh qualification rounds with identical named outcomes under grader `e3c5b795…` (`qualification-round-{1,2,3}.json`, `prepared-source-tree.json`).

## Changes

No reference changed in this batch.

| Case | Change | Wrong solutions now rejected |
| --- | --- | --- |
| cachex-pr-341 | A warmer that crashes while a `wait: true` call waits for it makes the failure reach the caller (an exit, a raise or an error, not `{:ok, list}`), as the ticket already said; the `waiting` text now says it too | catching the waiting call's exit and returning `{:ok, list}` (17/17 old) |
| livebeats-pr-37 | Without the Media Session API, pausing and resuming the first song keeps working. The hidden "no Media Session API" browser now also lacks the API's `window` globals, as a real browser without it does, so a solution that detects the API by `MediaMetadata` is no longer wrongly rejected | an unguarded `playbackState` write on pause (6/6 old) |
| livebook-pr-2527 | Content added before the stamp that starts with a Livebook annotation comment (cell options, or only an offset key) leaves the notebook unverified. Wording: whitespace between content and stamp is limited to blank lines, including lines of only spaces or tabs; a tab or four spaces before the stamp makes it a code block | accepting a remainder that starts with `<!-- livebook:`, or with an offset key (50/50 old each) |
| livebook-pr-2663 | A loose list keeps its nested bullets and code under items 9 and 10 unchanged, and nested content under items 1000 and 1001 keeps its text column. Wording: the round-trip promise now covers loose lists numbered consecutively from 1 | the old fixed indent in loose lists; an indent capped at three digits (50/50 old each) |
| livebook-pr-2822 | Wording only: a failed cell's modules are unloaded when their `defmodule` ran to completion. A module whose `@after_compile` raises stays loaded on the reference, so the text no longer promises otherwise | none needed |
| pinchflat-pr-610 | A yt-dlp message ending in a newline is recorded exactly, newline included (new test). For blank yt-dlp output the reason contains the printed error term, as the text already said | storing the trimmed message; a fixed text for blank output (21/21 old each) |
| plausible-pr-6449 | Submitting a different slug with a rename still saves the rename, as the text already said | dropping the whole edit but still reporting "Shared link saved" (35/35 old) |
| vutuv-pr-1759 | Among followed accounts, handle-prefix matches come before name-only matches (new test). A page's avatar is a `/organization_images/<logo token>/…` URL. `\` in a term is literal. A one-character non-ASCII term returns nothing. The ranking, literal-term and page-avatar requirement texts now say what the ticket said | a three-tier ranking; the bare logo token; leaving `\` unescaped; a byte-length minimum (24/24 old each) |

Opus's run-E patches pass every new check. Opus's run B, C and D patches for livebeats-pr-37 also pass its new fixture.

## Left as they are

- **livebook-pr-2800:** an empty, whitespace-only or comment-only cell reports a parse error without a line, column or marker, though the requirement promises all four for any unparseable cell. A visible test already pins this, so no solver is misled.
- **pinchflat-pr-610:** five existing `CommandRunnerTest` tests fail on the untouched source because `/tmp` is not executable in the workspace. Grading runs with the same mount, and no graded command includes them.
- **vutuv-pr-1759:** a `PageScreenshotTest` test fails in the workspace's full suite, and the clarification names such environment failures only in general. No graded command includes it.
- **plausible-pr-6449 and others:** `reference-tests.patch` lags `acceptance.patch` in several bundles. Grading never uses it.

## Status

- **Qualification:** all 8 changed cases passed three fresh qualification rounds with identical named outcomes under grader `e3c5b795…`. Each exported bundle is exactly its reviewed draft plus its admission receipt.
- **Release:** the restored release has 20 cases. The controller's inventory matches the checkout and every admission verifies. The 12 cases this batch did not touch are byte-identical to before.
- **Forks:** every case's preparation and reference branches point at the commits its provenance records.
- **Harness fixes in the same commit:** the session-level workspace server in the solver kit, the patch snapshot that leaves the solver's git index alone, and 1 GB for PostgreSQL. The controller's full suite passes in the tooling image (247 tests).
- **Validation:** all 20 cases need two Opus validation attempts under the new solver kit; see the [validation record](../opus-validation-2026-10-26/README.md).
