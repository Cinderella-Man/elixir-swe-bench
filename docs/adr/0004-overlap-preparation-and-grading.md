# Overlap preparation and grading around ordered Pi attempts

Prepare the first case before other cases, then prepare upcoming cases while one Pi attempt runs. Preserve inventory order, hold at most one additional pristine workspace, and grade saved submissions independently in a single grading lane. Bound the submission queue so a slow or blocked grader cannot accumulate unlimited pending work. This hides independent setup and grading work where possible while keeping model conversations serial and workspace ownership explicit; it does not guarantee uninterrupted Pi execution.

Reuse immutable broken-source images, pristine source snapshots and matching qualification receipts on the same Docker host. Never promote agent edits, reference repairs, grader overlays or mutable database state into reusable preparation. Run cancellation must drain every worker and subprocess before removing owned containers. The design assumes a remote model server while retaining support for local endpoints; preparation concurrency remains configurable because the Docker host may be shared.

Amended by [ADR 0014](0014-run-a-runs-attempts-in-parallel.md): a run may hold several attempts, waiting workspaces and grading lanes at once. With one parallel attempt, the default, this ADR's behaviour is unchanged.
