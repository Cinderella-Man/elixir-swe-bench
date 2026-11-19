Complete the bug_fix task in /workspace. Investigate the source and run the relevant tests.
Test command: mix test test/livebook/live_markdown/import_test.exs.
Add or change a test that fails in its test body on the starting source and passes after your change. Compilation/setup failures do not count.
Required outcome (altered-notebook-unverified): When content is added to a signed notebook between its signed portion and its stamp, whether a new Elixir or Erlang code cell, a markdown paragraph or a new section, importing it still imports every section and cell, including the added content, but reports the stamp as not verified and restores no hub secret names. The import gives exactly one warning: the existing message for a stamp that fails verification, which for a personal-hub notebook says that it can only access environment variables defined in this machine.
Required outcome (valid-stamps-still-verify): Unaltered signed notebooks still verify: a notebook freshly exported and signed by Livebook, including one with a non-ASCII name, imports with its stamp verified, no warnings and its hub secret names restored. Blank lines between the signed content and its stamp, including lines holding only spaces or tabs, keep the stamp valid, with the same result.
Dependencies are prepared. The workspace is offline. Preserve existing behavior and do not weaken tests.

Allowed edit prefixes: lib/, test/. Changes anywhere else are discarded before grading.
When finished, give a short summary. Your current patch is then checked in a fresh workspace.
Model and tool calls are unlimited, and so are generated tokens. The only limit is the context window: 262144 tokens for the whole conversation, your replies included.
History is never compacted. When the context window is full, the current patch is graded.
Task details: {"environment":"Historical dependencies and application assets are prepared. Tests run offline with working loopback and no external services.","verification":"Add or update a *_test.exs regression test under test/. It must expose the reported defect in the original code and pass after repair. Preserve existing behavior."}
