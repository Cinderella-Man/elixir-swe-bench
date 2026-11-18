Complete the bug_fix task in /workspace. Investigate the source and run the relevant tests.
Test command: mix test test/plausible/cache_test.exs test/plausible_web/plugs/tracker_plug_test.exs.
Add or change a test that fails in its test body on the starting source and passes after your change. Compilation/setup failures do not count.
Required outcome (scripts-follow-writes): With the application cache enabled, as in a running Community Edition instance, a site's dedicated tracker script at `/js/<tracker script configuration id>.js` is served with status 200 after its configuration is created, and after each later successful configuration update, including repeated changes back and forth, it reflects the latest settings such as file downloads and outbound links. No restart or manual cache refresh is needed. Each script is valid JavaScript for its own site's domain, and changing one site's configuration leaves other sites' scripts unchanged.
Required outcome (cache-refresh-keeps-scripts-current): Refreshing the existing tracker script cache (`:tracker_script_cache`) from the current configurations, as the periodic cache refresh does, keeps every dedicated script current and specific to its site through repeated configuration changes, including changes not made through this node, such as a configuration updated directly in the database or by another node: after such a refresh, the script is served with status 200 and reflects the stored settings. Repeated refreshes do not make script requests fail.
Required outcome (unknown-tracker-not-found): A request for a dedicated tracker ID that has no configuration still returns 404.
Dependencies are prepared. The workspace is offline. Preserve existing behavior and do not weaken tests.

Allowed edit prefixes: lib/, test/, extra/lib/. Changes anywhere else are discarded before grading.
When finished, give a short summary. Your current patch is then checked in a fresh workspace.
Model and tool calls are unlimited, and so are generated tokens. The only limit is the context window: 262144 tokens for the whole conversation, your replies included.
History is never compacted. When the context window is full, the current patch is graded.
Task details: {"edition":"Community Edition. Use MIX_ENV=ce_test, which is already set. PostgreSQL and ClickHouse are ready inside the offline workspace network.","verification":"Add or update a *_test.exs regression test under test/. It must expose the reported defect in the original code and pass with your repair. Existing checks must remain valid."}
