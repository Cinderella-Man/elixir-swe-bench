Complete the feature task in /workspace. Investigate the source and run the relevant tests.
Test command: node --test test/benchmark/preservation.mjs.
Add or change a test that fails in its test body on the starting source and passes after your change. Compilation/setup failures do not count.
Required outcome (now-playing): When a song starts playing, show its title and artist in the browser tab and supported Media Session metadata, updating whenever the playing song changes, whether a song is picked from the list or the player's Next and Previous controls change it. When listening stops on the profile's song list page, the tab returns to that page's ordinary title.
Required outcome (optional-api): Keep ordinary playback working in browsers without the Media Session API.
Dependencies are prepared. The workspace is offline. Preserve existing behavior and do not weaken tests.
Chromium and Playwright are preinstalled. Node tests can import process.env.EAB_BROWSER_MODULE. Bind any test web server to loopback and close browsers/servers after each suite.
Allowed edit prefixes: lib/, assets/, test/. Changes anywhere else are discarded before grading.
When finished, give a short summary. Your current patch is then checked in a fresh workspace.
Model and tool calls are unlimited, and so are generated tokens. The only limit is the context window: 262144 tokens for the whole conversation, your replies included.
History is never compacted. When the context window is full, the current patch is graded.
Task details: {"environment":"PostgreSQL and offline Chromium are prepared. Browser tests use Node test with Playwright from EAB_BROWSER_MODULE; the local test helper seeds accounts and signs normal application sessions without GitHub OAuth. Regression tests are Node test files ending in .mjs under test/; ExUnit files do not count for this task."}
