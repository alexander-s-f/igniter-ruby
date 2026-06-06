# Track: Durable Model Client Projection Descriptor v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target packages: `packages/igniter-durable-model`, `packages/igniter-ledger-client`, `packages/igniter-ledger`

## Context

Client-backed Durable Model now supports the common remote boundary:

- `register`
- `write`
- `read`
- `scope`
- `on_scope`
- `append`
- `replay`
- `replay(partition:)`
- relation auto-wire
- `register_relation`
- typed `resolve`
- `_relations`
- `metadata_snapshot`
- `descriptor_snapshot`

The next embedded-vs-client gap is projection metadata.

Embedded Durable Model has:

```ruby
store.register_projection(:tracker_dashboard,
  reads: [:trackers, :tracker_logs],
  relations: [:logs_by_tracker],
  consumer_hint: :contract_node,
  reactive: true
)

store._projections
```

Client-backed Durable Model still raises for projection registration and
projection snapshots. Ledger already has protocol-level projection descriptors,
but the current handler is narrower than Durable Model's surface: it accepts
`source` and does not preserve `relations` / `consumer_hint` cleanly.

This slice should make projections a transport-safe metadata contract. It
should not add remote projection execution.

## Goal

Make client-backed Durable Model support:

- `register_projection`
- `_projections`
- `_scatters` metadata snapshot when available remotely

Keep `register_scatter` unsupported in client-backed mode, because scatter rules
carry Ruby callables and are not a protocol-safe transport contract.

Desired remote shape:

```ruby
client = Igniter::LedgerClient.wrap(ledger.protocol)
store = Igniter::DurableModel::Store.new(client: client)

store.register_projection(:tracker_dashboard,
  reads: [:trackers, :tracker_logs],
  relations: [:logs_by_tracker],
  consumer_hint: :contract_node,
  reactive: true
)

store._projections[:tracker_dashboard]
# => {
#      name: :tracker_dashboard,
#      reads: [:trackers, :tracker_logs],
#      relations: [:logs_by_tracker],
#      consumer_hint: :contract_node,
#      reactive: true,
#      store_count: 2,
#      relation_count: 1
#    }
```

## Required Shape

### 1. Extend Ledger projection descriptor input

Update `Igniter::Store::Protocol::Handlers::ProjectionHandler` so it accepts both
the old and new descriptor spellings:

Old spelling:

```ruby
{
  schema_version: 1,
  kind: :projection,
  name: :open_task_counts,
  source: :tasks,
  mode: :on_demand
}
```

New Durable Model spelling:

```ruby
{
  schema_version: 1,
  kind: :projection,
  name: :tracker_dashboard,
  reads: [:trackers, :tracker_logs],
  relations: [:logs_by_tracker],
  consumer_hint: :contract_node,
  reactive: true
}
```

Normalization guidance:

- `reads` wins when present.
- `source` remains accepted for backward compatibility.
- `mode: :materialized` should still imply `reactive: true` unless `reactive`
  is explicitly present.
- `relations` defaults to `[]`.
- `consumer_hint` defaults to `:protocol_client`.
- reject descriptors with no `name`.
- reject descriptors with neither `reads` nor `source`.

Do not introduce projection execution semantics. This is OP1/OP2 metadata only.

### 2. Client-backed `register_projection`

For client-backed `Igniter::DurableModel::Store`, lower:

```ruby
store.register_projection(name, reads:, relations:, consumer_hint:, reactive:)
```

to:

```ruby
@inner.register_descriptor(
  schema_version: 1,
  kind: :projection,
  name: name,
  reads: Array(reads).map(&:to_sym),
  relations: Array(relations).map(&:to_sym),
  consumer_hint: consumer_hint,
  reactive: reactive
)
```

Keep embedded behavior unchanged.

Maintain a small local projection registry in Durable Model if needed so
`_projections` does not have to expose raw protocol envelopes.

### 3. Client-backed `_projections`

Return a compact projection snapshot compatible with embedded
`SchemaGraph#projection_snapshot`:

```ruby
{
  tracker_dashboard: {
    name: :tracker_dashboard,
    reads: [:trackers, :tracker_logs],
    relations: [:logs_by_tracker],
    consumer_hint: :contract_node,
    reactive: true,
    store_count: 2,
    relation_count: 1
  }
}
```

Implementation options:

- Prefer remote `metadata_snapshot[:projections]` if it already matches this
  shape.
- Fall back to the local Durable Model projection registry if the remote is
  unavailable or older.

Do not return raw Ledger protocol envelopes from `_projections`.

### 4. Client-backed `_scatters`

Support read-only scatter snapshots in client-backed mode:

```ruby
store._scatters
```

Mapping:

- use `metadata_snapshot[:scatters]`
- normalize keys to symbols
- return `[]` when the remote does not expose scatters

This is important because client-backed relation auto-wire registers Ledger
relation descriptors, and the Ledger engine materializes those relations through
scatter rules. Operators should be able to inspect that generated graph.

Keep this explicit gap:

```ruby
store.register_scatter(...)
# => NotImplementedError
```

### 5. Docs

Update Durable Model docs:

- client-backed mode now supports projection descriptor registration and
  `_projections`
- `_scatters` is read-only metadata in client-backed mode
- `register_scatter` and causation chains still require embedded Ledger
- projections are metadata-only; no remote projection execution is promised

## Non-Goals

- No remote projection execution.
- No materialized projection runtime.
- No projection query planner.
- No remote `register_scatter`.
- No serialization of Ruby callables.
- No causation-chain parity in this slice.
- No public v1 API guarantee.

## Suggested Read Set

1. `packages/igniter-durable-model/lib/igniter/durable_model/store.rb`
2. `packages/igniter-durable-model/spec/igniter/companion/store_spec.rb`
3. `packages/igniter-ledger/lib/igniter/store/protocol/handlers/projection_handler.rb`
4. `packages/igniter-ledger/lib/igniter/store/protocol/interpreter.rb`
5. `packages/igniter-ledger/lib/igniter/store/schema_graph.rb`
6. `packages/igniter-ledger/spec/igniter/store/protocol/op1_spec.rb`
7. `packages/igniter-ledger/spec/igniter/store/schema_graph_spec.rb`
8. `packages/igniter-ledger-client/lib/igniter/ledger_client/client.rb`
9. `packages/igniter-ledger-client/spec/igniter/ledger_client/client_spec.rb`
10. `packages/igniter-durable-model/README.md`
11. `packages/igniter-durable-model/README.ru.md`

Do not read the whole repository. This is a projection descriptor / metadata
parity slice.

## Acceptance

Done means:

- Ledger protocol projection handler accepts both `source` and `reads`.
- Ledger protocol projection handler preserves `relations`, `consumer_hint`, and
  `reactive`.
- Existing projection descriptor specs still pass.
- Client-backed Durable Model `register_projection` lowers to Ledger projection
  descriptor.
- Client-backed Durable Model `_projections` returns embedded-compatible
  snapshot shape.
- Client-backed Durable Model `_scatters` returns remote metadata snapshot
  instead of raising.
- Client-backed Durable Model `register_scatter` still raises a clear
  `NotImplementedError`.
- Embedded Durable Model projection/scatter behavior is unchanged.
- Docs list projection metadata parity as supported and remote scatter
  registration as unsupported.

Required tests:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec
```

If the full Ledger suite is too expensive for the current turn, at minimum run:

```bash
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec/igniter/store/protocol/op1_spec.rb packages/igniter-ledger/spec/igniter/store/schema_graph_spec.rb
```

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-durable-model/client-projection-descriptor-v0
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

## Final Notes

- Ledger projection descriptors now accept both legacy `source` and Durable
  Model `reads` forms, preserving `relations`, `consumer_hint`, and `reactive`.
- Client-backed Durable Model now supports metadata-only `register_projection`
  and `_projections`.
- Client-backed `_scatters` is read-only metadata from the Ledger snapshot;
  `register_scatter` remains unsupported because it carries Ruby callables.
- This slice should make projection metadata travel over the same controlled
  Ledger Client boundary as records, histories, scopes, subscriptions, replay,
  and relations.
- Keep the boundary honest: descriptors are transport-safe data; Ruby scatter
  callables are embedded-engine behavior.
