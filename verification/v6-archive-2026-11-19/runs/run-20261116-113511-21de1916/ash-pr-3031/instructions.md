Complete the bug_fix task in /workspace. Investigate the source and run the relevant tests.
Test command: mix test test/calculations test/sort/sort_test.exs.
Add or change a test that fails in its test body on the starting source and passes after your change. Compilation/setup failures do not count.
Required outcome (valid-arguments): Valid scalar and array calculation arguments, including atom/string names and supported expressions, must behave consistently across loads, filters and sorts while retaining cast and constrained literal values. Beside an expression argument, a literal argument is cast and constrained once and the calculation uses exactly that value when it is loaded or filtered: it must not be cast, constrained or coerced again, including in typed comparisons within calculation expressions, because a type's cast need not accept or preserve its own output.
Required outcome (input-errors): Malformed argument containers, unknown arguments and custom-type callback rejections must produce structured input errors; retain useful callback error messages.
Required outcome (preserve-boundaries): Keep user-facing filter_input expression rejection in both map and tuple forms, required/optional/default argument semantics including normalized nil, and ordinary expression coercion. In tuple filters, a nil argument container means omitted arguments and still applies defaults.
Dependencies are prepared. The workspace is offline. Preserve existing behavior and do not weaken tests.

Allowed edit prefixes: lib/, test/. Changes anywhere else are discarded before grading.
When finished, give a short summary. Your current patch is then checked in a fresh workspace.
Model and tool calls are unlimited, and so are generated tokens. The only limit is the context window: 262144 tokens for the whole conversation, your replies included.
History is never compacted. When the context window is full, the current patch is graded.
Task details: {"environment":"Elixir 1.20.2 / OTP 29.0.5 and locked dependencies are prepared. Focused calculation/sort tests use private ETS data with no external services. Add regression tests under test/; functional checks use seed 0. Test output is buffered by writer until complete lines are available. ExUnit defaults to at most two concurrent test cases."}
