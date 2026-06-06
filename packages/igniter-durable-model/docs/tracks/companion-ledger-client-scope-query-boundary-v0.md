# Track: Companion Ledger Client Scope Query Boundary v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target packages: `packages/igniter-companion`, `packages/igniter-ledger-client`, `packages/igniter-ledger`

## Context

`Igniter::Companion::Store.new(client: client)` now proves the preferred remote
Ledger boundary for the minimum durable surface:

- record descriptor registration
- record write/read
- history descriptor registration
- history append/plain replay
- metadata and descriptor snapshots

The remaining first user-visible gap is `scope`.

Embedded Companion can do:

```ruby
store.scope(Reminder, :open)
```

Client-backed Companion currently raises `NotImplementedError` for scope queries.
That is the right v0 fail-fast behavior, but it should be the next boundary to
promote because ordinary application code reads record sets through scopes.

The important protocol detail: current `LedgerClient#query` result exposes
`results` as value hashes only. Companion records need stable keys too. Do not
solve this by guessing keys or leaking embedded `Fact` objects across the client
boundary.

## Goal

Make client-backed Companion support simple record scopes by lowering them to
standard `LedgerClient#query`.

Desired app shape:

```ruby
client = Igniter::LedgerClient.remote_http("http://127.0.0.1:7300/v1/dispatch")
store = Igniter::Companion::Store.new(client: client)

store.register(Reminder)
store.write(Reminder, key: "r1", title: "Buy milk", status: :open)

open = store.scope(Reminder, :open)
# => [#<Reminder key="r1" title="Buy milk" status=:open>]
```

## Required Shape

### 1. Protocol query row model

Extend query responses with a stable row shape:

```ruby
{
  items: [
    { key: "r1", value: { title: "Buy milk", status: :open } }
  ],
  results: [
    { title: "Buy milk", status: :open }
  ],
  count: 1
}
```

Guidance:

- `items` is the canonical client-facing row model.
- `results` remains for backward compatibility and should keep its existing
  value-only semantics.
- Do not expose engine `Fact` objects as the canonical query response.
- Preserve `order`, `limit`, and `as_of` behavior.
- Preserve old tests that assert `results`.

### 2. LedgerClient result model

Extend `Igniter::LedgerClient::Results::QueryResult`:

- add `#items`
- keep `#results`
- keep `#count`
- keep `#to_h`
- normalize string/symbol keys where local code already does so

The client should remain transport-first and must not depend on `igniter-ledger`
runtime classes.

### 3. Companion client-backed scope

Implement `Igniter::Companion::Store#scope` for `client:` mode:

- look up the Companion scope definition on the record class
- lower `filters:` to `LedgerClient#query(store:, where:, as_of:)`
- build records from `QueryResult#items`
- use item `key` as the record key
- use item `value` as record fields

Keep embedded scope behavior unchanged.

### 4. Clear remaining gaps

This slice should not implement:

- `on_scope` remote subscriptions
- relation resolve over client
- projection/scatter client-backed behavior
- partitioned history replay
- remote access-path planner optimization
- server-side scope names as a new protocol primitive

Those gaps should keep clear `NotImplementedError` messages where they are still
unsupported.

## Suggested Read Set

1. `packages/igniter-companion/docs/tracks/companion-ledger-client-remote-boundary-v0.md`
2. `packages/igniter-companion/lib/igniter/companion/store.rb`
3. `packages/igniter-companion/lib/igniter/companion/record.rb`
4. `packages/igniter-companion/spec/igniter/companion/store_spec.rb`
5. `packages/igniter-ledger-client/lib/igniter/ledger_client/results.rb`
6. `packages/igniter-ledger-client/spec/igniter/ledger_client/client_spec.rb`
7. `packages/igniter-ledger/lib/igniter/store/protocol/interpreter.rb`
8. `packages/igniter-ledger/lib/igniter/store/protocol/wire_envelope.rb`
9. Relevant ledger protocol query specs under `packages/igniter-ledger/spec`

Do not read the whole repository. This is a narrow protocol-boundary slice.

## Acceptance

Done means:

- Protocol `query` can return `items` with `{ key:, value: }`.
- Existing query `results` behavior is preserved.
- `LedgerClient::Results::QueryResult#items` works.
- Client-backed Companion `scope` works for simple declared filters.
- Client-backed Companion `scope(..., as_of:)` works if protocol `query` already
  supports `as_of`.
- Embedded Companion scope behavior is unchanged.
- Unsupported remote `on_scope` still fails clearly.
- No dependency from `igniter-ledger-client` to `igniter-ledger`.
- Docs mention that remote `scope` is now supported but subscriptions/relations
  remain v0 gaps.

Required tests:

```bash
BUNDLE_GEMFILE=packages/igniter-companion/Gemfile bundle exec rspec packages/igniter-companion/spec
bundle exec rspec packages/igniter-ledger-client/spec
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec
```

If the full ledger suite needs local sockets, run it outside the sandbox.

## Final Notes

- Protocol `query` now returns canonical `items` rows with `{ key:, value: }`
  while preserving value-only `results` and `count`.
- `Igniter::LedgerClient::Results::QueryResult` exposes `#items`, `#results`,
  `#count`, `#to_h`, and normalizes local/remote key shapes without depending on
  `igniter-ledger` classes.
- Client-backed `Igniter::Companion::Store#scope` lowers declared scope filters
  to `LedgerClient#query(store:, where:, as_of:)` and rebuilds typed records from
  query item keys and values.
- Embedded scope behavior is unchanged.
- Client-backed `on_scope`, relations, projection/scatter behavior, causation,
  key-filtered history, and partition replay remain explicit v0 gaps.

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-companion/companion-ledger-client-scope-query-boundary-v0
Status: done | partial | blocked

[D] Decisions:
- ...

[S] Shipped:
- ...

[T] Tests:
- ...

[R] Risks / next recommendations:
- ...
```
