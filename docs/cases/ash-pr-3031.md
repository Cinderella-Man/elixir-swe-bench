# Keep calculation arguments consistent across loads filters and sorts

**Case** `ash-pr-3031` · **Bug fix** in [Ash](https://github.com/ash-project/ash)

Ash calculations take arguments when loaded or used in filters and sorts, but the three paths handle them inconsistently. Mixing literal and expression arguments can reject valid input or crash, cast literals can change value beside an expression argument, and malformed argument containers, unknown arguments or custom-type rejections escape as internal errors instead of structured input errors. Valid arguments, named by atom or string, must behave alike on every path, defaults must still apply, and `filter_input` must still reject expression arguments.

- [Ticket the agent receives](../../cases/ash-pr-3031/ticket.md)
- [Case files](../../cases/ash-pr-3031/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/ash-project/ash/pull/3031) the case is based on
