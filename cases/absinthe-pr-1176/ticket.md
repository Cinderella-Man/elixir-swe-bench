# Schema declarations with descriptions, directives and extensions

## Goal

A GraphQL schema declaration is the `schema { query: … mutation: … subscription: … }` block that names a schema's root operation types. Tools such as Apollo Federation 2 attach type-system directives to it (for example `schema @link(…) { … }`), and the GraphQL specification allows it to carry a description and to be extended with `extend schema`.

Absinthe schemas must support this in both notations:

- Macro schemas (`use Absinthe.Schema` with the notation macros) can write a declaration with a description, directives and operation entries, and can extend it.
- SDL schemas (`import_sdl`) can extend their declaration, and their declared description and directives take effect.
- Root objects defined with `query`, `mutation` and `subscription` can be extended like other objects.

The declaration must show up in `Absinthe.Schema.to_sdl/1` and in introspection, and operations must execute against the declared roots.

## Public interface

Macro notation, inside a schema module:

| Form | Where | Contents |
| --- | --- | --- |
| `schema do … end` | Top level, at most once | `description "…"`, `directive :name, args`, and operation entries `field :query, :query`, `field :mutation, :mutation`, `field :subscription, :subscription` |
| `extend schema do … end` | Top level, any number | `directive :name, args` and operation entries as above |
| `extend object(:query) do … end`, likewise `:mutation` and `:subscription` | Top level | Fields and directives, as in any `extend object(…)` |

Operation entries name the root object by its identifier. The roots are the objects defined with `query`, `mutation` and `subscription`.

SDL notation, inside `import_sdl`:

```graphql
"Description of the schema"
schema @feature(name: "x") {
  query: Query
  mutation: Writes
}

extend schema @feature(name: "y") {
  subscription: Feed
}

extend schema @feature(name: "z")
```

A directive is usable on a declaration when its definition includes the schema location, for example `on [:schema]` in a prototype schema or `on SCHEMA` in SDL.

Results are observed through:

- `Absinthe.Schema.to_sdl/1`;
- introspection: `{ __schema { description queryType { name } mutationType { name } subscriptionType { name } } }`;
- operation execution.

No new public function is required. Schemas that use `@schema_provider Absinthe.Schema.PersistentTerm` must behave exactly like schemas that use the default provider.

## Decided behaviour

### Writing a declaration in a macro schema

```elixir
defmodule MyApp.Schema do
  use Absinthe.Schema
  # The prototype defines `directive :feature` with an `arg :name, :string`,
  # usable `on [:schema, :object]`.
  @prototype_schema MyApp.SchemaPrototype

  schema do
    description "Catalog API"
    directive :feature, name: "catalog"
    field :query, :query
    field :mutation, :mutation
  end

  query do
    field :ping, :string
  end

  mutation name: "Writes" do
    field :touch, :string
  end
end
```

- Introspection reports `description: "Catalog API"`, `queryType { name: "RootQueryType" }` and `mutationType { name: "Writes" }`.
- `Absinthe.Schema.to_sdl/1` begins with the declaration:

  ```graphql
  "Catalog API"
  schema @feature(name: "catalog") {
    query: RootQueryType
    mutation: Writes
  }
  ```

- As today, the declaration is the first thing rendered, preceded only by its description when it has one. Descriptions are rendered like type descriptions, so a multi-line description becomes a block string. Directives are rendered after `schema` in the same format as on types. Each operation entry takes one line, `operation: TypeName`, in an unspecified order.
- In macro schemas, the roots are still the objects defined with `query`, `mutation` and `subscription`. Operation entries describe those roots; they do not create, rename or remove any. A defined root that the declaration does not list still executes and appears in introspection, but it is not listed in the rendered `schema` block. A declaration should list `query`.

### The inferred declaration

A schema without a written declaration has an inferred one. It lists every root the schema defines:

- in macro schemas, the objects defined with `query`, `mutation` and `subscription`;
- in SDL schemas, the types named `Query`, `Mutation` and `Subscription`.

It has no description, and has directives only if extensions add them. `to_sdl` renders it as a `schema { … }` block, as it does today.

### The schema description

- `__schema { description }` returns the description of the declaration: the `description` in a macro `schema` block, or the description string written before an SDL `schema`. It is `null` when there is none.
- The text "Represents a schema" is the description of the `__Schema` introspection type, not of the user's schema. It must no longer be reported as the schema's description, and no longer be rendered above the `schema` block. This intentionally changes existing output, and existing tests that expect it need updating.

### Extending the declaration

- `extend schema` applies to the written declaration, or to the inferred one when none is written. This holds in both notations.
- Every extension's directives are added to the declaration, and its operation entries are added to the declaration's entries. Any number of extensions may be used.
- In SDL schemas, a type that an extension names for an operation becomes that operation's root, exactly as if the declaration had named it. Introspection reports it, operations of that kind execute against it, and `to_sdl` lists it.

  ```graphql
  schema {
    query: Query
  }

  type Query { ping: String }
  type Writes { touch: String }

  extend schema @feature(name: "extended") {
    mutation: Writes
  }
  ```

  Here `mutationType` is `Writes`, `mutation { touch }` executes, and `to_sdl` renders:

  ```graphql
  schema @feature(name: "extended") {
    query: Query
    mutation: Writes
  }
  ```

  The same applies without the written `schema { query: Query }` block. The inferred declaration then lists `query: Query` and the extension adds `mutation: Writes`.
- In macro schemas, an extension entry such as `field :mutation, :mutation` lists an existing root, following the macro rule above.
- The order of the directives, and of the operation entries, within the rendered `schema` block is not specified.

### Extending root objects

- `extend object(:query) do … end` adds fields and directives to the root object that `query do … end` defines, exactly like extending any other object. `extend object(:mutation)` and `extend object(:subscription)` do the same for their roots.
- Extending a root object that the schema does not define fails like extending any other undefined type: compilation raises `Absinthe.Schema.Error`.
- Defining an object with `object :query`, `object :mutation` or `object :subscription` outside `extend` is still rejected. It raises `Absinthe.Schema.Notation.Error` with the existing message "Invalid schema notation: cannot create an `object` with reserved identifier `query`" (with the identifier used). Roots are defined with the `query`, `mutation` and `subscription` macros.

## Errors

All of these are raised when the schema module is compiled.

| Situation | Error |
| --- | --- |
| `schema` or `extend schema` used anywhere other than the top level of the schema module, such as inside an `object` | `Absinthe.Schema.Notation.Error`, like other misplaced notation |
| More than one declaration: two `schema` blocks, or two SDL `schema` definitions | `Absinthe.Schema.Error` |
| A directive on a declaration or a schema extension that is unknown, or not defined for the schema location | `Absinthe.Schema.Error`. This also applies to SDL declarations, which were not checked before. |
| An operation entry, in a declaration or an extension and in either notation, that names an undefined type or root object | `Absinthe.Schema.Error` |

## Scope and non-goals

- Checking that an operation is not named twice across a declaration and its extensions is out of scope.
- Behaviour of a declaration without a `query` entry is out of scope.
- In a macro declaration, an entry that names an object which is not a root, such as `field :mutation, :thing`, is undecided and out of scope.
- Extensions do not add or change descriptions.
- GraphQL introspection does not expose applied directives, and this task does not add them.
- Macro schemas keep choosing their roots from the `query`, `mutation` and `subscription` macros. SDL schemas keep choosing theirs from the declaration, or by the type names `Query`, `Mutation` and `Subscription`.

## Compatibility

- Existing macro and SDL schemas compile and execute as before. Their `to_sdl` output is unchanged, with two exceptions: the placeholder description line no longer appears, and the order of entries in the `schema` block is not specified.
- Existing type extensions, directives on types and fields, and placement rules for other notation macros keep working.
- The default schema provider and `Absinthe.Schema.PersistentTerm` behave the same.
