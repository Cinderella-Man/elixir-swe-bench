# Case fixes after the third Opus validation run, 2026-10-27

Reviews of [Opus validation run `20261027-095752-a0aaa695`](../opus-validation-2026-10-26/README.md) (run D) read each of its 18 passing patches against its ticket, requirements, reference and hidden tests. Every pass was genuine: no weakened or deleted test, no special-casing of hidden data, no edit outside the allowed paths. In 9 cases, though, a plausible wrong solution also passed every hidden test, a text promised more than the reference does, or the reference broke a stated requirement. Unlike the earlier batches, every claim was run before anything changed: each wrong solution was built as a patch and shown to pass the released checks. The same standard as [the first](../case-fixes-2026-10-26/README.md) and [second](../case-fixes-2026-10-27/README.md) batches applies: every task, reference and check must be right.

## How each change was proven

Each change ran in throwaway containers built from the case's prepared image, mirroring the grader's hidden stage, against:

- the reference;
- Opus's patch from run D;
- the untouched starting source, which must fail exactly the listed starting failures in test bodies;
- the case's partial-fix control, which must still fail;
- one or more **wrong solutions** the change targets. Each passed the released checks and fails the new ones. They are kept per case under `wrong-fixes/`; for a corrected reference, the previous reference is one of them;
- every wrong solution kept by the earlier batches for the case, which must still fail.

Checks involving processes, browsers or shared state ran at least three times on the reference. Independent reviewers then approved every changed bundle against its exact file hashes (`independent-review.json`). One reviewer first rejected plausible-pr-6449 because a changed test kept a name that no longer matched what it checks; the test was renamed, re-proven and approved on a fresh review. Finally each case passed three fresh qualification rounds with identical named outcomes under grader `ba6b3fe3…` (`qualification-round-{1,2,3}.json`, `prepared-source-tree.json`).

## Changes

| Case | Change | Wrong solutions now rejected |
| --- | --- | --- |
| guardian-pr-748 | `VerifyHeader` and `VerifySession` with `:refresh_from_cookie` hand a missing connection secret (no tenant) and a wrong one to the cookie refresh: with no refresh cookie the request continues without a token and the error handler is not called, as the ticket already said | sending a missing secret straight to the error handler, in both plugs or in `VerifySession` only (22/22 old each) |
| livebook-pr-2663 | A fenced code block with a blank line under item 10 of a tight list comes back unchanged. Wording: the "come back unchanged" promise is limited to lists numbered consecutively from 1, because the formatter renumbers a list starting at 10 | deleting blank lines inside tight list items, which corrupts code (49/49 old) |
| livebook-pr-2822 | A failed evaluation does not roll back the random seed state, as the text already said | restoring a full process-dictionary snapshot after a failed cell (55/55 old) |
| plausible-pr-5956 | After a configuration is changed outside this node's writes (directly in the database or by another node), a cache refresh serves the current script, through a change and a change back. Stated in the ticket and requirement | keeping the `:bag` table with delete-then-put writes (a refresh then returns two scripts, a 500); serving the last of several cached scripts (3/3 old each) |
| plausible-pr-6449 | The upgrade-required test could never fail: under the test setup the flash is never rendered, and its other branch always matched. It now checks the observable refusal (nothing saved, no "Shared link saved") and is renamed accordingly; the text describes the refusal instead of an error message. A value one above the largest segment ID is out of range | creating a link without the plan check; a 19-digit bound that crashes the database driver (35/35 old each) |
| livebeats-pr-37 | Stopping on the profile's song list page restores that page's title after playback carried on through a full page load of another page | restoring a title cached when playback started (5/5 old) |
| cachex-pr-341 | `modules:` accepts warmer names exactly like `only:`, in configuration order, as the ticket already said | `modules:` matching modules only (16/16 old) |
| pinchflat-pr-610 | **Reference corrected**: when yt-dlp fails with empty or whitespace-only output, the reference recorded no reason and cleared an earlier one, so the item dropped out of Failed although it had just failed; it now records `Unknown error: …` like other non-text errors, with retries unchanged. Checks for that, for a long reason with reserved characters and a newline recorded exactly, and for that reason shown escaped and in full everywhere the ticket says it is shown | the previous reference; storing a 255-character slice; cutting the reason in table rows or on the home page with no full text; rendering it unescaped, in the page or in the tooltip only; keeping the earlier reason on a blank failure (18/18 old each) |
| beacon-pr-687 | **Reference corrected**: `beacon_sitemap_index/1` imported `Phoenix.Router` with `only:` inside its expansion, which replaced the router's own import, so `pipe_through`, `get/3`, `post` or `scope/2` declared after it failed to compile. It now calls `Phoenix.Router` fully qualified. The ticket states that routes and scopes after it keep working, at the top level and in a scope | the previous reference; widening the macro's import list (10/10 old each) |

Opus's run-D patches fail two of the new checks: beacon-pr-687 (it shared the reference's import leak) and pinchflat-pr-610 (it stored whitespace-only yt-dlp output verbatim as the reason). Both cases restart validation anyway. Opus's run-B and run-C patches for beacon-pr-687 pass the new check. Every other run-D patch passes its case.

The reference corrections are curator commits on the forks' reference branches, recorded in each case's `provenance.json`:

- [pinchflat](https://github.com/Cinderella-Man/pinchflat/pull/1): `137c7cee`
- [beacon](https://github.com/Cinderella-Man/beacon/pull/1): `78c9d769`

Each reconstructs its recorded fixed tree from the baseline plus the bundle's patches.

## Left as they are

- **pinchflat-pr-610:** cutting the reason only in the media item page's Last Error section is not caught, because the same page's raw attributes list always prints the full reason, so the full text is in the page markup as the ticket requires.
- **livebook-pr-2663:** a line inside a fenced code block that holds only spaces comes back empty. That is the Markdown parser's behaviour, older than this task, and no check depends on it.
- **livebook-pr-2822:** the evaluator's own process-dictionary keys are stated as shared and not rolled back, but only the random-seed half of that sentence is checked; the check already rejects the over-broad repair both halves describe.
- **plausible-pr-5956:** a solution that both writes the cache asynchronously and fills it on a miss could in principle race its own creation write, as it already could between the released test's iterations.
- **cachex-pr-341:** "a warmer matched by several entries is triggered once" is checked through the result list, not through how often the warmer runs.

## Status

- **Qualification:** all 9 changed cases passed three fresh qualification rounds with identical named outcomes under grader `ba6b3fe3…`. In every round the reference passes and the starting source, the partial fix and the early exit all fail. Each exported bundle is exactly its reviewed draft plus its admission receipt.
- **Release:** the restored release has 20 cases. The controller's inventory matches the checkout and every admission verifies. The 11 cases this batch did not touch are byte-identical to before.
- **Forks:** every case's preparation and reference branches point at the commits its provenance records.
- **Controller tests:** the full suite passes in the tooling image (247 tests).
- **Validation:** the 9 changed cases need two new Opus validation attempts on their new versions, and the other 11 one or two under the parallel-attempts kit; see the [validation record](../opus-validation-2026-10-26/README.md).
