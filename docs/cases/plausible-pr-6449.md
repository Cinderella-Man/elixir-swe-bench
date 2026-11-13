# Shared-link editing accepts fields outside the link's boundaries

**Case** `plausible-pr-6449` · **Bug fix** in [Plausible Analytics](https://github.com/plausible/analytics)

Plausible Analytics shared links expose a site's dashboard at a secret URL, optionally tied to one of the site's segments. The create and edit forms let a user overwrite a link's URL or attach another site's segment. Editing must keep the URL fixed, and an empty, invalid, nonexistent or other-site segment selection must save the remaining valid changes with no segment, while valid same-site segments keep working.

- [Ticket the agent receives](../../cases/plausible-pr-6449/ticket.md)
- [Case files](../../cases/plausible-pr-6449/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/plausible/analytics/pull/6449) the case is based on
