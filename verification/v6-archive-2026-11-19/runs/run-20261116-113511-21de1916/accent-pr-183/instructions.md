Complete the feature task in /workspace. Investigate the source and run the relevant tests.
Test command: mix test test/web/controllers/export_controller_test.exs test/web/controllers/sync_controller_test.exs test/web/controllers/merge_controller_test.exs.
Add or change a test that fails in its test body on the starting source and passes after your change. Compilation/setup failures do not count.
Required outcome (compatible-version): Allow file exports (the regular export and the in-place translation (JIPT) export) and sync/merge requests, including their previews, to select a project's translation version with a semantic version requirement. Select the highest compatible version in that project, whatever order its versions were created in, accepting stored tags with a leading v and ignoring non-version tags.
Required outcome (literal-priority): Prefer an exact literal tag when present.
Required outcome (preserve-existing): Preserve the existing outcomes for unmatched requests and requests without a version, and preserve translations outside the selected version and project.
Dependencies are prepared. The workspace is offline. Preserve existing behavior and do not weaken tests.

Allowed edit prefixes: lib/, test/. Changes anywhere else are discarded before grading.
When finished, give a short summary. Your current patch is then checked in a fresh workspace.
Model and tool calls are unlimited, and so are generated tokens. The only limit is the context window: 262144 tokens for the whole conversation, your replies included.
History is never compacted. When the context window is full, the current patch is graded.
Task details: {"environment":"Elixir 1.12.3/OTP 23.3.4.20, local PostgreSQL and native YAML are prepared. Dependency compatibility shims supply native YAML, preserve legacy helper bindings and exclude unused documentation dependencies from application startup. Use the existing endpoint tests with local bearer credentials; no external accounts or reporting are needed."}
