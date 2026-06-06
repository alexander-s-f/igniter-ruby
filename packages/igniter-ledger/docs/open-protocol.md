# Igniter Ledger Open Protocol

Status date: 2026-05-02.

Status: shipped (OP0–OP5 implemented). The protocol surface is live in
`packages/igniter-ledger` and `packages/igniter-companion`. Not yet a stable
public API — packets and opcodes may evolve before v1.

## Claim

`igniter-ledger` should stay inside the Igniter ecosystem, but it should not be
locked to `Igniter::Contract`.

The target shape is an open thin waist:

```text
many contract systems
custom DSLs
agents and simulations
external apps
        |
        v
Igniter Ledger Open Protocol
descriptor packets / fact packets / receipts / queries / subscriptions
        |
        v
igniter-ledger fact engine
memory / file WAL / LedgerServer / sync hub / future native backends
```

Igniter contracts are a first-class client of the protocol, not the only client.

## Metaphor

Lego, not ORM.

The protocol exposes a small set of studs:

- register descriptors
- write immutable facts
- append history events
- read current and `as_of`
- query access paths
- resolve relations
- subscribe to invalidations
- replay WAL or server facts
- sync cold hubs later

Every client can bring its own contract system if it can speak these studs.

## Thin Waist

The protocol waist is made of packets, not framework classes:

- Descriptor packets: what exists.
- Fact packets: what happened or what is currently true.
- Receipt packets: what was accepted, rejected, deduplicated, or derived.
- Query packets: what view of facts is requested.
- Subscription packets: what invalidation stream is requested.
- Sync packets: what should move across process, machine, or storage boundary.

Above the waist:

- Igniter contracts.
- Companion application contracts.
- External DSLs.
- JS/TS workflow engines.
- Agent memory systems.
- IoT or simulation event models.
- Future visual schema editors.

Below the waist:

- In-memory backend.
- File WAL backend.
- LedgerServer.
- PostgreSQL sync hub.
- Native/Rust acceleration.
- Future cluster replication.

## Protocol Objects

### Store Descriptor

```ruby
{
  schema_version: 1,
  kind: :store,
  name: :tasks,
  key: :id,
  fields: [
    { name: :id, type: :string, required: true },
    { name: :title, type: :string },
    { name: :status, type: :symbol, default: :open }
  ],
  capabilities: [:write, :current_read, :as_of_read],
  producer: { system: :igniter_contract, name: :Task }
}
```

### History Descriptor

```ruby
{
  schema_version: 1,
  kind: :history,
  name: :task_events,
  key: :task_id,
  event_field: :event,
  timestamp_field: :at,
  producer: { system: :custom_dsl, name: :TaskTimeline }
}
```

### Access Path Descriptor

```ruby
{
  schema_version: 1,
  kind: :access_path,
  name: :tasks_by_status,
  store: :tasks,
  fields: [:status],
  unique: false
}
```

### Relation Descriptor

```ruby
{
  schema_version: 1,
  kind: :relation,
  name: :project_tasks,
  from: { store: :projects, key: :id },
  to: { store: :tasks, field: :project_id },
  cardinality: :many
}
```

### Projection Descriptor

```ruby
{
  schema_version: 1,
  kind: :projection,
  name: :open_task_counts,
  source: :tasks,
  group_by: [:project_id],
  compute: { count_where: { status: :open } }
}
```

### Derivation Descriptor

```ruby
{
  schema_version: 1,
  kind: :derivation,
  name: :today_focus,
  inputs: [:tasks, :calendar_events],
  output: :focus_items,
  mode: :materialized
}
```

### Command Descriptor

```ruby
{
  schema_version: 1,
  kind: :command,
  name: :complete,
  owner: :reminders,
  operation: :record_update,
  target_shape: :store,
  boundary: :app,
  mutation_intent: :record_update,
  changes: { status: :done }
}
```

Command descriptors are metadata-only app-boundary contracts. Ledger records
the command vocabulary and mutation intent, but it does not execute commands or
call app code.

### Effect Descriptor

```ruby
{
  schema_version: 1,
  kind: :effect,
  name: :complete,
  owner: :reminders,
  store_op: :store_write,
  write_kind: :update,
  lowers_to: :store_t,
  boundary: :app,
  source_operation: :record_update
}
```

Effect descriptors describe the persistence intent a command lowers to. They
are metadata-only; side effects still happen at the app boundary.

### Subscription Descriptor

```ruby
{
  schema_version: 1,
  kind: :subscription,
  name: :open_tasks_changed,
  source: :tasks,
  where: { status: :open },
  events: [:write, :delete, :compact]
}
```

### Fact Packet

```ruby
{
  schema_version: 1,
  kind: :fact,
  store: :tasks,
  key: "t1",
  value: { id: "t1", title: "Draft protocol", status: :open },
  value_hash: "sha256:...",
  causation: nil,
  producer: { system: :external_client, name: :demo },
  at: "2026-05-02T10:30:00Z"
}
```

Rules:

- `value_hash` identifies content.
- Fact id identifies store/key/version identity.
- `causation` points to the previous fact id or command fact.
- Facts are append-only; current state is a projection over facts.

### Write Receipt

```ruby
{
  schema_version: 1,
  kind: :receipt,
  status: :accepted,
  store: :tasks,
  key: "t1",
  fact_id: "fact_...",
  value_hash: "sha256:...",
  warnings: [],
  derived: []
}
```

## Minimal Operations

Descriptor registry:

- `register_store(descriptor)`
- `register_history(descriptor)`
- `register_access_path(descriptor)`
- `register_relation(descriptor)`
- `register_projection(descriptor)`
- `register_derivation(descriptor)`
- `register_command(descriptor)`
- `register_effect(descriptor)`
- `register_subscription(descriptor)`
- `metadata_snapshot`

Fact IO:

- `write(store:, key:, value:, causation: nil, producer: nil)`
- `append(history:, event:, key: nil, partition_key: nil, producer: nil)`
- `read(store:, key:, as_of: nil)`
- `query(store:, where: {}, order: nil, limit: nil, as_of: nil)`
- `history(store:, key: nil, from: nil, to: nil)`
- `history_partition(store:, partition_key:, partition_value:, from: nil, to: nil)`
- `causation_chain(store:, key:)`
- `lineage(store:, key:)`
- `fact_ref(fact_id)`

Provenance operations are read-only. `fact_ref` returns compact fact metadata
for boundary redirects and audit links; full arbitrary `fact_by_id` value reads
remain engine-local / future debug tooling.

Relations, projections, and derivations:

- `resolve(relation:, from:, as_of: nil)`
- `relation_snapshot(name, as_of: nil)`
- `projection_snapshot(name, as_of: nil)`
- `derivation_snapshot(name, as_of: nil)`
- `scatter_snapshot(name, as_of: nil)`

Retention and compaction:

- `register_retention(descriptor)`
- `retention_snapshot`
- `compact(store:, before:, policy:)`

Server and wire:

- `write_fact(packet)`
- `replay(from: nil, to: nil, filter: nil)` where filter may be
  `{ store: }`, `{ store:, key: }`, or
  `{ store:, partition_key:, partition_value: }`
- `causation_chain(store:, key:)`
- `lineage(store:, key:)`
- `fact_ref(fact_id)`
- `subscribe(subscription_packet)`
- `stats`
- `drain`

## Boundaries

The open protocol must not require:

- `Igniter::Contract`
- Ruby DSL execution
- ORM classes
- SQL schema generation
- Rails conventions
- app command semantics
- materializer execution
- cluster consensus

The protocol may be implemented by:

- current Ruby `igniter-ledger`
- LedgerServer
- a future native backend
- a PostgreSQL sync hub adapter
- external compatible engines
- test doubles and simulators

## Non-Igniter Client Example

```ruby
store.register_store(
  schema_version: 1,
  kind: :store,
  name: :tasks,
  key: :id,
  fields: [
    { name: :id, type: :string, required: true },
    { name: :status, type: :symbol }
  ],
  producer: { system: :demo_dsl, name: :Task }
)

store.register_access_path(
  schema_version: 1,
  kind: :access_path,
  name: :tasks_by_status,
  store: :tasks,
  fields: [:status]
)

receipt = store.write(
  store: :tasks,
  key: "t1",
  value: { id: "t1", status: :pending },
  producer: { system: :demo_dsl, name: :TaskFlow }
)

open = store.query(store: :tasks, where: { status: :pending })
```

The client does not need to know Igniter internals. It only needs descriptors,
facts, and receipts.

## Versioning

Every packet carries:

- `schema_version`
- `kind`
- optional `capabilities`
- optional `producer`
- optional `extensions`

Compatibility rules:

- Unknown optional keys are ignored.
- Unsupported required capabilities produce structured rejection receipts.
- Protocol versions evolve by adding packet kinds or optional fields first.
- Breaking changes require a new `schema_version`.

## Implemented Slices

### OP0: Vocabulary

Canonical names for descriptors, facts, receipts, queries, subscriptions,
lineage, retention, and sync are defined and used throughout the codebase.

### OP1: Descriptor Packet Import

Shipped: `Protocol::Interpreter` (7 handler classes), content-addressed SHA256
dedup, named helpers `register_store` / `register_history` / `register_access_path` /
`register_relation` / `register_projection` / `register_derivation` /
`register_command` / `register_effect` / `register_subscription`.
Command/effect descriptors are metadata-only and app-boundary owned.
Protocol-level `write` / `write_fact` / `read` / `append` / `query(where:)` /
`resolve`. Receipt contract:
`:accepted | :rejected | :deduplicated` + write/append receipts with `fact_id`
and `value_hash`.

### OP2: Metadata Export

Shipped: `Protocol::Interpreter#metadata_snapshot` returns unified snapshot
(`stores`, `histories`, `access_paths`, `relations`, `projections`, `derivations`,
`commands`, `effects`, `scatters`, `subscriptions`, `retention`).
`descriptor_snapshot` includes raw store/history/command/effect/subscription
descriptors. Companion, LedgerServer, and visual tools consume one endpoint.

### OP3: Wire Envelope

Shipped: `Protocol::WireEnvelope` dispatches op envelope hashes to Interpreter.
Operations include `register_descriptor`, `write`, `append`, `write_fact`,
`read`, `query`, `resolve`, `metadata_snapshot`, `descriptor_snapshot`,
`sync_hub_profile`, and `replay`.
Response envelope: `{ protocol:, schema_version:, request_id:, status:, result: }`.
Error safety net: unexpected raises → error response. Pure Ruby — no I/O.

`append` is append-only history semantics. A client may include `key:` in the
packet, but protocol v0 returns the generated fact key and does not treat
client-supplied `key:` as a stable idempotency guarantee.

```ruby
{
  protocol: :igniter_store,
  schema_version: 1,
  request_id: "req_...",
  op: :write_fact,
  packet: { kind: :fact, store: :tasks, key: "t1", value: {} }
}
```

### OP4: Sync Hub Profile

Shipped: `SyncProfile` value object with `full?` / `incremental?` / `fact_count` /
`next_cursor`. Cursor: `{ kind: :timestamp, value: Float }` — hub persists and sends
back on next sync to receive only new facts. `Interpreter#sync_hub_profile(as_of:, cursor:, stores:)`.
`Interpreter#replay(from:, to:, filter:)`. `IgniterStore#fact_log_all(since:, as_of:)`.

Profile carries:
- accepted fact log
- descriptor registry snapshot (`metadata_snapshot`)
- retention policy snapshot
- compaction receipts
- replay cursors
- subscription checkpoints

### OP5: Companion Protocol Adoption

Shipped: `Companion::Store#register` emits `:store` or `:history` descriptor via
`@inner.register_descriptor` for every new schema class. Record classes
(detected via `respond_to?(:_scopes)`) produce `:store` descriptors with
`fields`, `capabilities`, and `producer: { system: :igniter_companion }`.
History classes produce `:history` descriptors with the declared `partition_key`.
Record command/effect metadata emits `:command` and `:effect` descriptors, which
preserve `command -> mutation_intent -> app boundary` without adding command
execution to Ledger.
`Companion::Store#metadata_snapshot` / `#descriptor_snapshot` delegate to
`@inner.protocol` — companion-managed schemas appear in the OP2 unified snapshot.

## Out-Of-Box Ideas

### Protocol As Contract Constitution

Contracts become local constitutions over store facts. Different ecosystems can
write different constitutions while sharing the same fact substrate.

### Store Compliance Kit

Create a tiny compatibility suite: any backend that passes descriptor import,
fact write, causation, query, history, replay, and subscription tests can call
itself `igniter-ledger protocol compatible`.

### Fact-Native Plugin Marketplace

Plugins publish descriptors and derivations instead of migrations only. An app
can install a plugin by registering its descriptor pack and replaying seed facts.

### Store Browser

A protocol-native inspector can browse descriptors, facts, causation chains,
relations, projections, and retention pressure without knowing app classes.

### Multi-Language Clients

The packet model makes JS/TS, Python, Swift, or Rust clients feasible before
the Ruby DSL reaches final form.

### Capability Firewall

External clients can be granted capabilities per descriptor:

- read-only facts
- append-only histories
- scoped writes
- subscription-only access
- metadata-only inspection

This becomes useful for agents and decentralized human-agent interfaces.
