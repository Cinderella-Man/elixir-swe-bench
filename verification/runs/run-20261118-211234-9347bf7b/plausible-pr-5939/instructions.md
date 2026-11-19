Complete the bug_fix task in /workspace. Investigate the source and run the relevant tests.
Test command: mix test test/plausible_web/live/change_domain_test.exs.
Add or change a test that fails in its test body on the starting source and passes after your change. Compilation/setup failures do not count.
Required outcome (editors-change-domain): Editors can change a site's domain from its change-domain form, whether they are a guest Editor of that site or an Editor member of the site's team. Submitting a new domain stores it as the site's domain and records the previous domain as the one it was changed from, as it already does for owners and admins, who keep this ability.
Required outcome (editor-access-stays-site-scoped): Editor access to the form applies only to sites on which the user is an Editor. A team Editor gains no access to another team's site, and a guest Editor of one site who is only a Viewer of another site in the same team cannot open that other site's form. Like viewers and users without access to the site, such users are refused with the existing not-found error (`Ecto.NoResultsError`) when opening the form, and the site's domain is left unchanged.
Dependencies are prepared. The workspace is offline. Preserve existing behavior and do not weaken tests.

Allowed edit prefixes: lib/, test/, extra/lib/. Changes anywhere else are discarded before grading.
When finished, give a short summary. Your current patch is then checked in a fresh workspace.
Model and tool calls are unlimited, and so are generated tokens. The only limit is the context window: 262144 tokens for the whole conversation, your replies included.
History is never compacted. When the context window is full, the current patch is graded.
Task details: {"edition":"Community Edition. Use MIX_ENV=ce_test, which is already set. PostgreSQL and ClickHouse are ready inside the offline workspace network.","verification":"Add or update a *_test.exs regression test under test/. It must expose the reported defect in the original code and pass with your repair. Existing checks must remain valid."}
