Complete the bug_fix task in /workspace. Investigate the source and run the relevant tests.
Test command: mix test test/livebook_web/live/session_live_test.exs test/livebook/session/data_test.exs.
Add or change a test that fails in its test body on the starting source and passes after your change. Compilation/setup failures do not count.
Required outcome (frame-update-inputs-appear): In a notebook session, when a frame update adds inputs to an existing frame, whether it replaces the frame's contents or appends to them, and including a frame nested inside another frame, the open session page shows each new input (for example text and number inputs) in the cell's outputs with its label and default value once the session has processed the update and the page re-renders, with no other interaction. Outputs already shown around the updated frame, such as a sibling text output in the enclosing frame, remain displayed.
Required outcome (frame-update-inputs-work): Inputs added by frame updates work like any other input: the session data records each one's current value in input_infos, starting from its default; editing one on the page sends the usual change event with the new value to the input's destination; and an edited value is kept, both on the page and in the session data, when a later frame update appends more inputs to the same frame.
Dependencies are prepared. The workspace is offline. Preserve existing behavior and do not weaken tests.

Allowed edit prefixes: lib/, test/. Changes anywhere else are discarded before grading.
When finished, give a short summary. Your current patch is then checked in a fresh workspace.
Model and tool calls are unlimited, and so are generated tokens. The only limit is the context window: 262144 tokens for the whole conversation, your replies included.
History is never compacted. When the context window is full, the current patch is graded.
Task details: {"environment":"Historical dependencies and application assets are prepared. Tests run offline with working loopback and no external services.","verification":"Add or update a *_test.exs regression test under test/. It must expose the reported defect in the original code and pass after repair. Preserve existing behavior."}
