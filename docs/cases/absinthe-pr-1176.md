# Declare, extend and render GraphQL schema declarations with directives

**Case** `absinthe-pr-1176` · **Feature** in [Absinthe](https://github.com/absinthe-graphql/absinthe)

Absinthe builds GraphQL APIs in Elixir from schemas written with notation macros or imported SDL. In both notations, the `schema { … }` declaration that names the root operation types must accept a description and directives, as Apollo Federation 2 uses, and be extendable with `extend schema`; the query, mutation and subscription root objects must accept `extend object(…)`. `Absinthe.Schema.to_sdl/1` and introspection must show the declaration and its description, and operations must run against the declared roots.

- [Ticket the agent receives](../../cases/absinthe-pr-1176/ticket.md)
- [Case files](../../cases/absinthe-pr-1176/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/absinthe-graphql/absinthe/pull/1176) the case is based on
