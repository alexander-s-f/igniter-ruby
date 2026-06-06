# Track: Durable Model Client Provenance Introspection v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target packages: `packages/igniter-durable-model`, `packages/igniter-ledger-client`, `packages/igniter-ledger`

## Context

Client-backed Durable Model now supports the main remote boundary:

- record/history registration
- write/read/query/scope
- scope subscriptions
- append/replay/partition replay
- relation descriptors and typed resolve
- projection descriptors and projection snapshots
- read-only scatter snapshots
- metadata and descriptor snapshots

The remaining high-value gap is provenance.

Embedded Durable Model supports:

```ruby
store.causation_chain(Reminder, key: "r1")
```

But client-backed Durable Model still raises:

```text
client-backed Durable Model store does not support causation chains in v0
```

Ledger already has engine-level provenance primitives:

- `Igniter::Ledger::LedgerStore#causation_chain(store:, key:)`
- `Igniter::Ledger::LedgerStore#lineage(store:, key:)`
- `Igniter::Ledger::LedgerStore#fact_ref(fact_id)`
- `Igniter::Ledger::LedgerStore#fact_by_id(fact_id)`

Those are not yet part of the standard protocol/client boundary. This slice
should expose the read-only provenance surface without introducing any mutation
or cleanup command.

## Goal

Add read-only provenance introspection through the Ledger protocol and Ledger
Client, then use it to close Durable Model's client-backed `causation_chain`
gap.

Desired shape:

```ruby
client = Igniter::LedgerClient.wrap(ledger.protocol)
store = Igniter::DurableModel::Store.new(client: client)

store.register(Reminder)
store.write(Reminder, key: "r1", title: "One")
store.write(Reminder, key: "r1", title: "Two")

store.causation_chain(Reminder, key: "r1")
# => [{ id:, value_hash:, causation:, transaction_time: }, ...]

client.lineage(store: :reminders, key: "r1")
# => { subject:, chain:, depth:, derived_by:, proof_hash: }

client.fact_ref(fact_id)
# => { id:, store:, key:, transaction_time:, valid_time:, value_hash: } | nil
```

## Required Shape

### 1. Protocol operations

Add read-only operations to both protocol envelopes:

- `:causation_chain`
- `:lineage`
- `:fact_ref`

Files likely involved:

- `packages/igniter-ledger/lib/igniter/store/protocol/interpreter.rb`
- `packages/igniter-ledger/lib/igniter/store/protocol/wire_envelope.rb`
- `packages/igniter-ledger-client/lib/igniter/ledger_client/envelope.rb`

Suggested packet shapes:

```ruby
{ op: :causation_chain, packet: { store: :reminders, key: "r1" } }
{ op: :lineage, packet: { store: :reminders, key: "r1" } }
{ op: :fact_ref, packet: { fact_id: "..." } }
```

Suggested response shapes:

```ruby
# causation_chain
{ chain: [...], count: 2 }

# lineage
{
  subject: { store: :reminders, key: "r1" },
  chain: [...],
  depth: 2,
  derived_by: [],
  proof_hash: "..."
}

# fact_ref
{ found: true, ref: { id:, store:, key:, transaction_time:, valid_time:, value_hash: } }
{ found: false, ref: nil }
```

Keep `fact_by_id` out of the public client surface for this slice. Returning full
fact values by arbitrary id is more sensitive and can be added later if we need
debug/deep-recovery tooling. `fact_ref` is enough for boundary redirects,
relation edges, and compact provenance.

### 2. Ledger Client API

Add client methods:

```ruby
client.causation_chain(store:, key:)
client.lineage(store:, key:)
client.fact_ref(fact_id)
```

Normalize local object dispatch and remote JSON hash responses.

Result-model guidance:

- `causation_chain` can return `Results::CausationChainResult` with
  `chain`, `count`, `to_h`, and `[]`.
- `lineage` can return `Results::LineageResult` with
  `subject`, `chain`, `depth`, `derived_by`, `proof_hash`, `to_h`, and `[]`.
- `fact_ref` can return `Results::FactRefResult` with
  `found?`, `ref`, `to_h`, and `[]`.

If the implementation cost is too high, keep `lineage` raw for v0, but prefer a
small model because this surface is compact and will be used by Durable Model,
boundary tools, and operators.

### 3. Durable Model client-backed `causation_chain`

Change:

```ruby
store.causation_chain(schema_class, key:)
```

for client-backed mode to lower through:

```ruby
@inner.causation_chain(store: schema_class.store_name, key: key)
```

Return the same array shape as embedded mode:

```ruby
[
  { id:, value_hash:, causation:, transaction_time: },
  ...
]
```

Do not expose Ledger Client result objects from Durable Model.

### 4. Optional Durable Model `lineage`

If low churn, add:

```ruby
store.lineage(schema_class, key:)
```

for both embedded and client-backed modes.

Embedded:

```ruby
@inner.lineage(store: schema_class.store_name, key: key)
```

Client-backed:

```ruby
@inner.lineage(store: schema_class.store_name, key: key)
```

This is optional for acceptance because the current public Durable Model gap is
`causation_chain`. If added, document it as read-only provenance introspection.

### 5. MCP adapter

Add the three operations as read-only MCP tools:

- `causation_chain`
- `lineage`
- `fact_ref`

They should be in `READ_TOOLS`, mapped through `TOOL_TO_OP`, and exposed in
`tool_list`. They must not enable writes, compaction, prune, purge, or arbitrary
fact reads.

### 6. Docs

Update docs where relevant:

- `packages/igniter-ledger/docs/open-protocol.md`
- `packages/igniter-ledger-client/README.md`
- `packages/igniter-durable-model/README.md`
- `packages/igniter-durable-model/README.ru.md`

Clarify:

- provenance ops are read-only
- `fact_ref` returns compact metadata only
- `fact_by_id` remains engine-local / future debug surface
- client-backed Durable Model now supports `causation_chain`

## Non-Goals

- No mutation commands.
- No compaction/prune/purge execution.
- No physical cleanup policy changes.
- No remote `fact_by_id`.
- No auth/TLS.
- No cross-ledger distributed provenance.
- No guarantee that purged facts can still produce full chains; future boundary
  redirect and retained summaries may enrich this.

## Suggested Read Set

1. `packages/igniter-durable-model/lib/igniter/durable_model/store.rb`
2. `packages/igniter-durable-model/spec/igniter/companion/store_spec.rb`
3. `packages/igniter-ledger/lib/igniter/store/igniter_store.rb`
4. `packages/igniter-ledger/lib/igniter/store/protocol/interpreter.rb`
5. `packages/igniter-ledger/lib/igniter/store/protocol/wire_envelope.rb`
6. `packages/igniter-ledger/lib/igniter/store/mcp_adapter.rb`
7. `packages/igniter-ledger-client/lib/igniter/ledger_client/client.rb`
8. `packages/igniter-ledger-client/lib/igniter/ledger_client/envelope.rb`
9. `packages/igniter-ledger-client/lib/igniter/ledger_client/results.rb`
10. `packages/igniter-ledger/spec/igniter/store/lineage_spec.rb`
11. `packages/igniter-ledger/spec/igniter/store/igniter_store_fact_id_index_spec.rb`
12. `packages/igniter-ledger/spec/igniter/store/protocol/op3_spec.rb`
13. `packages/igniter-ledger/spec/igniter/store/mcp_adapter_spec.rb`
14. `packages/igniter-ledger-client/spec/igniter/ledger_client/client_spec.rb`

Do not read the whole repository. This is a read-only provenance protocol slice.

## Acceptance

Done means:

- `Protocol::Interpreter` exposes `causation_chain`, `lineage`, and `fact_ref`.
- `WireEnvelope::OPERATIONS` includes all three operations.
- Wire dispatch returns stable normalized response shapes.
- `LedgerClient::Envelope::OPERATIONS` includes all three operations.
- `LedgerClient` exposes `causation_chain`, `lineage`, and `fact_ref`.
- Ledger Client normalizes local object and remote JSON responses.
- MCP adapter exposes all three as read-only tools.
- Client-backed Durable Model `causation_chain` works and returns the embedded
  array shape.
- Embedded Durable Model `causation_chain` behavior is unchanged.
- Docs remove `causation_chain` from the client-backed unsupported list.
- No `fact_by_id` public client method is added.

Required tests:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec
```

If the full Ledger suite is too expensive for the current turn, at minimum run:

```bash
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec \
  packages/igniter-ledger/spec/igniter/store/protocol/op3_spec.rb \
  packages/igniter-ledger/spec/igniter/store/mcp_adapter_spec.rb \
  packages/igniter-ledger/spec/igniter/store/lineage_spec.rb \
  packages/igniter-ledger/spec/igniter/store/igniter_store_fact_id_index_spec.rb
```

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-durable-model/client-provenance-introspection-v0
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

- This closes the next important remote Durable Model gap without turning the
  client into a Ledger engine.
- Provenance is intentionally read-only and compact: chain, lineage proof, and
  fact refs.
- Protocol, Ledger Client, Durable Model, and MCP now share the same read-only
  provenance boundary.
- `fact_by_id` remains outside the public client/MCP surface; `fact_ref` is the
  compact cross-boundary reference.
- This surface will also support future boundary redirect, cleanup guard, and
  Spark CRM audit/debug workflows.
