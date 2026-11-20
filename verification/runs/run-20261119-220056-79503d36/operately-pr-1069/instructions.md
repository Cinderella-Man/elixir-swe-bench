Complete the bug_fix task in /workspace. Investigate the source and run the relevant tests.
Test command: mix test test/operately_web/api/mutations/post_project_check_in_test.exs.
Add or change a test that fails in its test body on the starting source and passes after your change. Compilation/setup failures do not count.
Required outcome (unique-recipients): Keep one subscription per distinct person among the author, selected recipients and mentioned people, including an author who mentions themselves and a person mentioned more than once, whichever id form a mention uses. Explicitly invited people, and the author, keep invited status when they are also mentioned.
Required outcome (preserve-check-ins): Preserve ordinary check-in creation and all distinct recipients, including when the explicit recipient list is omitted or empty.
Dependencies are prepared. The workspace is offline. Preserve existing behavior and do not weaken tests.

Allowed edit prefixes: lib/, test/. Changes anywhere else are discarded before grading.
When finished, give a short summary. Your current patch is then checked in a fresh workspace.
Model and tool calls are unlimited, and so are generated tokens. The only limit is the context window: 262144 tokens for the whole conversation, your replies included.
History is never compacted. When the context window is full, the current patch is graded.
Task details: {"environment":"Historical dependencies and local PostgreSQL are prepared. API tests run offline with EAB_API_ONLY_TESTS=true; browser-only startup and custom report formatters are disabled for these API tests. No cloud accounts or external reporting are needed."}
