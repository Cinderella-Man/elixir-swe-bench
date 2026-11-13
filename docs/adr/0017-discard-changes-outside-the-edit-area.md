# Discard changes outside the edit area instead of rejecting the submission

Every case lists the path prefixes a solver may edit. Until now a submission that touched anything else was rejected whole, with no test run. Both published Sonnet 5.5 runs failed guardian-pr-748 that way: the ticket says documentation updates are welcome, the solver added a section to `README.md`, and `README.md` is not on that case's list. Re-graded without the README change, both patches pass every check. The same rule would reject a submission for a stray log left in the workspace, which 17 of the 20 workspaces do not ignore.

The grader now discards changes outside the edit area and grades the rest:

- **Saved submission:** the patch saved from the workspace covers the case's edit area and top-level source, script and note files. Anything else the agent left behind is not part of it.
- **Grading:** a change in the saved patch that is outside the edit area is dropped before the patch is applied, and its path is recorded as `discarded_files` in the grading evidence.
- **Still rejected:** a symbolic link or submodule inside the edit area, and a patch over 1 MiB.
- **Agent instructions:** after the allowed prefixes they say that changes anywhere else are discarded before grading.

The rule's purpose is unchanged. Configuration, dependencies and build files stay as the case prepared them, because an edit to them never reaches the graded workspace. A solution that needs such an edit still fails, on its tests instead of on its paths.

## Consequences

- A stray file can no longer decide an outcome, and a large one outside the edit area can no longer make the patch too big to save, which was an evaluation error.
- Case files do not change. guardian-pr-748 keeps its list; a README edit there is discarded.
- Grading evidence written before this change has no `discarded_files`.
- Qualification controls are unaffected: reference, partial and bypass patches must still stay inside the edit area when a case is admitted.

## Considered options

- **Add `README.md` to guardian-pr-748's list.** It fixes one case and leaves the rule able to zero a submission for any other stray path.
- **Reject only edits to tracked files and ignore new stray files.** A README edit would still fail a correct solution.
