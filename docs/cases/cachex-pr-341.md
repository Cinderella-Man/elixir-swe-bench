# Name cache warmers and warm selected warmers on demand

**Case** `cachex-pr-341` · **Feature** in [Cachex](https://github.com/whitfin/cachex)

In Cachex, warmers are modules that load values into a cache at startup and at intervals. Each warmer process is registered under its module name, so one module backs only one warmer, and `Cachex.warm/2` always returns before warming finishes. Warmer specs need an optional atom `name`, and `Cachex.warm/2` needs `only:` to trigger chosen warmers by name or module, `wait: true` to return once their values are in the cache, and a result listing the warmers it triggered.

- [Ticket the agent receives](../../cases/cachex-pr-341/ticket.md)
- [Case files](../../cases/cachex-pr-341/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/whitfin/cachex/pull/341) the case is based on
