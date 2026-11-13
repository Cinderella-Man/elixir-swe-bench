# Inputs introduced by frame updates render blank

**Case** `livebook-pr-2219` · **Bug fix** in [Livebook](https://github.com/livebook-dev/livebook)

In Livebook, a notebook frame is an output area that running code can update, and an update can add new inputs to it. Inputs added this way show up blank until the user interacts with the page. They must render in full as soon as the frame update arrives, without any interaction.

- [Ticket the agent receives](../../cases/livebook-pr-2219/ticket.md)
- [Case files](../../cases/livebook-pr-2219/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/livebook-dev/livebook/pull/2219) the case is based on
