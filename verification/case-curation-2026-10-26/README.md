# New feature cases, 2026-10-26

Feature cases added under [ADR 0013](../../docs/adr/0013-specify-feature-cases-with-grilled-specs.md): each ticket is a feature spec, and each reference may extend its upstream PR with a curator commit recorded separately in provenance. Candidates came from the [feature shortlist](../../docs/research/feature-case-shortlist-2026-10-26.md).

| Case | Upstream | Fork source pair | Curator extension |
| --- | --- | --- | --- |
| `absinthe-pr-1176` | absinthe-graphql/absinthe#1176 | [Cinderella-Man/absinthe#1](https://github.com/Cinderella-Man/absinthe/pull/1) | SDL `extend schema` roots become real roots; top-level root objects stay rejected; undefined declaration types raise `Absinthe.Schema.Error` |
| `cachex-pr-341` | whitfin/cachex#341, #342 | [Cinderella-Man/cachex#1](https://github.com/Cinderella-Man/cachex/pull/1) | Named warmers as supervisor children; duplicate and invalid identities rejected; module results and `:modules` restored; unbounded `wait: true` |
| `guardian-pr-748` | ueberauth/guardian#748 | [Cinderella-Man/guardian#1](https://github.com/Cinderella-Man/guardian/pull/1) | Per-request secrets for issuing tokens (`sign_in`, `remember_me`, `SlidingCookie`) with a fail-closed rule |
| `pinchflat-pr-610` | kieraneglin/pinchflat#610 | [Cinderella-Man/pinchflat#1](https://github.com/Cinderella-Man/pinchflat/pull/1) | A Failed tab and a "Retry Failed Downloads" source action that forces downloads of failed items |
| `beacon-pr-687` | BeaconCMS/beacon#687, #700 | [Cinderella-Man/beacon#1](https://github.com/Cinderella-Man/beacon/pull/1) | Every published page listed, XML-escaped locations, index skipping sites without Beacon routes, robots.txt as plain text |
| `vutuv-pr-1759` | wintermeyer/vutuv#1759 (server side) | [Cinderella-Man/vutuv#1](https://github.com/Cinderella-Man/vutuv/pull/1) | Members and pages ranked in one ordering with every exclusion applied in the query |

Each folder holds:

- `curator-notes.md`: investigation, assertion mapping, verification log and review amendments;
- `independent-review.json`: the approving review, bound to the exact draft hashes;
- `qualification-round-{1,2,3}.json`, `prepared-source-tree.json`, `source-preparation.json` and `source-review.json` from the shared qualification pipeline.

All six passed three fresh qualification rounds with identical named outcomes; their reference branches pass each project's full suite apart from tests that need network or tools the workspace lacks, which fail identically on the baseline. Every feature case's environment clarification states that added test files must compile on the starting source, and no spec mentions grading. Beacon moved to Elixir 1.18.4 during review because the locked dependencies need it. vutuv first failed qualification because upstream force-adds files its `.gitignore` excludes; the workspace commit now adds such files by name. Opus validation has not run yet.
