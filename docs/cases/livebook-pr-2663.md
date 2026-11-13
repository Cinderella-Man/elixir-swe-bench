# Long numbered lists lose nested content when formatted

**Case** `livebook-pr-2663` · **Bug fix** in [Livebook](https://github.com/livebook-dev/livebook)

Livebook saves notebooks as Markdown files. When a notebook contains a long numbered list, saving it breaks the nesting of the bullets and code blocks inside the list's items. After saving, nested bullets and code blocks must stay under the list items they belong to, however long the list is.

- [Ticket the agent receives](../../cases/livebook-pr-2663/ticket.md)
- [Case files](../../cases/livebook-pr-2663/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/livebook-dev/livebook/pull/2663) the case is based on
