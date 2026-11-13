# Project check-ins create duplicate notification subscriptions

**Case** `operately-pr-1069` · **Bug fix** in [Operately](https://github.com/operately/operately)

Posting a project check-in in Operately subscribes people to its notifications: the selected recipients, people mentioned in it, and the author. When the same person is selected or mentioned more than once, they get duplicate subscriptions. Each person must end up with one subscription, every distinct intended recipient must be kept, and an explicitly invited person stays invited even if also mentioned. Posting without an explicit recipient list must still work.

- [Ticket the agent receives](../../cases/operately-pr-1069/ticket.md)
- [Case files](../../cases/operately-pr-1069/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/operately/operately/pull/1069) the case is based on
