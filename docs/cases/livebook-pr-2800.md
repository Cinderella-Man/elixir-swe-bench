# Erlang syntax errors fail while formatting the diagnostic

**Case** `livebook-pr-2800` · **Bug fix** in [Livebook](https://github.com/livebook-dev/livebook)

Livebook notebooks can run Erlang code cells as well as Elixir ones. When an Erlang cell contains a syntax error, Livebook fails while formatting the diagnostic and shows an ArgumentError instead of the real problem. Evaluating such a cell must display the actual syntax error, also when the offending code contains non-ASCII characters.

- [Ticket the agent receives](../../cases/livebook-pr-2800/ticket.md)
- [Case files](../../cases/livebook-pr-2800/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/livebook-dev/livebook/pull/2800) the case is based on
