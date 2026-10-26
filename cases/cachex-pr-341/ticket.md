# Named cache warmers, selective warming and waiting for warming

## Goal

Give cache warmers optional names so that one warmer module can be used more than once, and give callers control over manual warming: warm only the warmers they choose, and optionally wait until warming has finished.

Today every warmer process is registered under its module name. One module can therefore back only one warmer: you cannot run the same database warmer against two sources in one cache, or use one warmer module in two caches at the same time. `Cachex.warm/2` can only be restricted by module and always returns immediately, so a caller (for example someone in a shell) cannot tell when the warmed values are actually in the cache.

## Decided behaviour

### Warmer names

- A warmer spec (`Cachex.Spec.warmer/1`) accepts a new optional `name` key alongside `module`, `state` and `async`. It defaults to `nil`.
- A name must be an atom. `nil` (or leaving the key out) means the warmer is unnamed.
- A named warmer's process is registered under its name, so `Process.whereis(name)` returns it while the cache is running.
- An unnamed warmer's process is no longer registered under its module name. This is what allows one module to back several warmers.
- Several warmers built from the same module can run in one cache as long as each has a different name. Each keeps its own `state`.
- The same unnamed warmer module can be used by several caches running at the same time.
- Startup warming is unchanged and applies to named warmers too: a warmer with `async: false` (the default) has finished its first run before `Cachex.start_link/2` returns; an `async: true` warmer runs in the background. Periodic re-warming on each warmer's `interval/0` is unchanged.

Example:

```elixir
import Cachex.Spec

Cachex.start_link(:users,
  warmers: [
    warmer(module: MyApp.DbWarmer, name: :primary_db_warmer, state: :primary),
    warmer(module: MyApp.DbWarmer, name: :replica_db_warmer, state: :replica),
    warmer(module: MyApp.ConfigWarmer)
  ]
)
```

### Warmer identity and validation

- Every warmer in a cache has an identity: its name when it has one, otherwise its module.
- Identities must be unique within one cache. Starting a cache returns `{:error, :invalid_warmer}`, and starts nothing, when:
  - two warmers have the same name, even if their modules differ;
  - two unnamed warmers use the same module;
  - an unnamed warmer's module is the same atom as another warmer's name.
- Starting a cache also returns `{:error, :invalid_warmer}` when a warmer's name is not an atom: for example a string (`"db"`), an integer, a list, or a tuple such as `{:global, :db}` or `{:via, Registry, {MyRegistry, :db}}`.
- Existing warmer validation (the module must implement `Cachex.Warmer`) is unchanged and keeps returning `{:error, :invalid_warmer}`.

### Selecting warmers with `only:`

- `Cachex.warm(cache, only: entries)` triggers only the warmers that match an entry. `entries` is a list of atoms.
- An entry that is a warmer name selects that warmer.
- An entry that is a module selects every warmer built from that module, named or unnamed.
- A warmer matched by several entries (for example by its module and by its name) is triggered once.
- Entries that match no warmer are ignored. `only: []` triggers nothing and returns `{:ok, []}`.
- Without `only:`, every warmer in the cache is triggered, as today.

### Waiting with `wait:`

- `wait: false` is the default and keeps today's behaviour: the selected warmers are triggered and the call returns without waiting for them to run.
- With `wait: true`, the call returns only after every selected warmer has finished its run, including writing the values it returned into the cache. A read straight after the call sees the warmed values.
- There is no timeout: a slow warmer is waited for however long it takes.
- `wait:` combines with `only:`. When nothing is selected, `wait: true` returns `{:ok, []}` straight away.

### Return value

`Cachex.warm/2` returns `{:ok, list}`. The list has one entry for each warmer that was triggered, in the order the warmers were given in the cache's `:warmers` option, regardless of the order of the `only:` entries. A named warmer is listed by its name, and an unnamed warmer by its module.

With the cache from the example above:

```elixir
Cachex.warm(:users)
#=> {:ok, [:primary_db_warmer, :replica_db_warmer, MyApp.ConfigWarmer]}

Cachex.warm(:users, only: [MyApp.DbWarmer])
#=> {:ok, [:primary_db_warmer, :replica_db_warmer]}

Cachex.warm(:users, only: [:replica_db_warmer, MyApp.ConfigWarmer], wait: true)
#=> {:ok, [:replica_db_warmer, MyApp.ConfigWarmer]}  (both runs have finished)

Cachex.warm(:users, only: [:no_such_warmer])
#=> {:ok, []}
```

## Edge cases and errors

- Invalid names and duplicate identities are rejected when the cache starts, with `{:error, :invalid_warmer}`. No warmer process is started or left registered.
- A name that is valid but already registered by another process (for example a named warmer used by two running caches) makes that cache fail to start, as with any registered process name clash. No particular error value is specified for this case.
- Calling `Cachex.warm/2` on a cache without warmers returns `{:ok, []}`, with or without `wait: true`.
- If a warmer crashes while a `wait: true` call is waiting for it, the failure reaches the caller. No particular recovery or error value is specified.

## Compatibility

- Existing warmer specs without a name keep working, and unnamed warmers are still reported by module in `Cachex.warm/2` results.
- An unnamed warmer that crashes and is restarted by the cache's supervisor keeps being reached by `Cachex.warm/2`, as today.
- The existing `modules:` option of `Cachex.warm/2` keeps working as an alias of `only:`: it accepts the same entries and behaves identically. If both are given, `only:` is used.
- The `Cachex.Warmer` behaviour (`interval/0`, `execute/1` and its return values) is unchanged. Warmer modules need no changes.
- Hook notifications are unchanged: a manual `Cachex.warm/2` call is reported to hooks as before, and starting a cache does not report a `:warm` action.
- Behaviour change: code that addressed a warmer process by its module name (for example `send(MyWarmer, …)` or `Process.whereis(MyWarmer)`) must give that warmer a name and use the name instead.

## Scope and non-goals

In scope: the `name` key on warmer specs, its validation, running and supervising named warmers, the `only:` and `wait:` options and the return value of `Cachex.warm/2`.

Out of scope:

- adding, removing or renaming warmers on a running cache;
- `{:global, …}` or `{:via, …}` registration of warmer processes;
- a timeout option for waiting;
- reporting what a warmer wrote, or whether it failed, in the result of `Cachex.warm/2`;
- renaming or changing the `async` flag or other existing warmer options;
- changes to how distributed (multi-node) caches handle warming;
- naming for hooks, which already support names.

## Public interface

- `Cachex.Spec.warmer/1`: record with keys `module`, `state`, `async` and the new `name` (atom or `nil`, default `nil`).
- `Cachex.start_link/2` and `Cachex.start/2` with the `:warmers` option: return `{:error, :invalid_warmer}` for an invalid warmer name or duplicate warmer identities.
- `Cachex.warm(cache, options \\ [])`:
  - `only:` list of warmer names and/or modules (default: all warmers);
  - `modules:` alias of `only:`;
  - `wait:` boolean (default `false`);
  - returns `{:ok, [atom]}`: the names of triggered named warmers and the modules of triggered unnamed warmers, in configuration order.
- A named warmer's process is registered locally under its name.
