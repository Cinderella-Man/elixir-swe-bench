# Failed evaluation erases earlier imports and process dictionary

**Case** `livebook-pr-2822` · **Bug fix** in [Livebook](https://github.com/livebook-dev/livebook)

Livebook evaluates notebook cells in order, and each cell can use the imports and process dictionary values set up by the successful cells before it. After a cell fails, later cells lose those imports and process dictionary values. A failed cell must leave the state from earlier successful cells intact, so cells evaluated after it can still use it.

- [Ticket the agent receives](../../cases/livebook-pr-2822/ticket.md)
- [Case files](../../cases/livebook-pr-2822/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/livebook-dev/livebook/pull/2822) the case is based on
