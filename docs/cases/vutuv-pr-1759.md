# Suggest @-mentions and report which handles will become links

**Case** `vutuv-pr-1759` · **Feature** in [vutuv](https://github.com/wintermeyer/vutuv)

In vutuv, members mention other members and organization pages by typing `@handle` in Markdown fields such as posts, but a mistyped handle is caught only when saving is refused. To back an editor @-picker, the server needs two JSON endpoints under `/system/mentions/`. One suggests accounts for a half-typed handle, followed accounts and handle-prefix matches first, never offering the writer or blocked, unconfirmed, moderation-hidden or non-public accounts. The other reports which handles in a draft the Markdown renderer will turn into mention links.

- [Ticket the agent receives](../../cases/vutuv-pr-1759/ticket.md)
- [Case files](../../cases/vutuv-pr-1759/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/wintermeyer/vutuv/pull/1759) the case is based on
