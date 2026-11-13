# Altered notebook retains signed secret authorization

**Case** `livebook-pr-2527` · **Bug fix** in [Livebook](https://github.com/livebook-dev/livebook)

Livebook can sign a notebook, which marks it as verified and authorizes it to use a hub's secrets. Adding code to a signed notebook leaves it verified and still authorized to use those secrets. Once its content has been altered, the notebook must no longer count as verified or be allowed to use hub secrets.

- [Ticket the agent receives](../../cases/livebook-pr-2527/ticket.md)
- [Case files](../../cases/livebook-pr-2527/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/livebook-dev/livebook/pull/2527) the case is based on
