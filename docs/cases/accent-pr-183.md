# Select compatible translation versions within a project

**Case** `accent-pr-183` · **Feature** in [Accent](https://github.com/mirego/accent)

In Accent, the regular and in-place translation (JIPT) file exports and sync and merge requests, previews included, can target one of a project's translation versions. They must also accept a semantic version requirement such as `~> 1.1`: an exact tag match still wins, otherwise the highest compatible version in that project is chosen, reading tags with a leading `v` as versions and skipping non-version tags. Unmatched requests and requests without a version behave as before.

- [Ticket the agent receives](../../cases/accent-pr-183/ticket.md)
- [Case files](../../cases/accent-pr-183/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/mirego/accent/pull/183) the case is based on
