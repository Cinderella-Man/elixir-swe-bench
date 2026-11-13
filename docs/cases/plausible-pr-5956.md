# Dedicated CE tracker scripts fail after creation or configuration changes

**Case** `plausible-pr-5956` · **Bug fix** in [Plausible Analytics](https://github.com/plausible/analytics)

Plausible Community Edition serves dedicated tracker scripts, each reflecting a stored tracker configuration. When a script is newly created or its configuration changes, requests for it return server errors until Community Edition is restarted. New and updated scripts must work without a restart, and a cache refresh must bring scripts up to date even when a configuration was changed directly in the database or by another node.

- [Ticket the agent receives](../../cases/plausible-pr-5956/ticket.md)
- [Case files](../../cases/plausible-pr-5956/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/plausible/analytics/pull/5956) the case is based on
