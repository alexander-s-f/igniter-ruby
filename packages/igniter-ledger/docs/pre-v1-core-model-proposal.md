# igniter-ledger Pre-v1 Core Model Proposal

Status date: 2026-05-03
Status: design proposal, subject to revision before v1
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Purpose

Strengthen the core model before v1 locks the wire format, Fact struct, and
derivation semantics. We have no backward-compatibility obligation and no
dependent production projects. Every change listed here becomes expensive after
v1. Now is the only cheap window.

## Design Criteria

Three criteria drive this proposal:

1. **Fast, effective storage** — storage must be efficient at the data-plane
   level, not just ergonomic at the Ruby API level.
2. **Always-explainable state** — given any fact, you must be able to answer
   "what is the state right now, what was it at time T, and why is it exactly
   that value?" without external audit tables or bolt-on paper trails.
3. **Bounded derivations can run near storage** — the store may host
   deterministic registered derivation evaluators, not arbitrary application
   workflows or side effects.

The gap against ActiveRecord is this: ActiveRecord gives you current state.
igniter-ledger must give you state at any point in time plus an explanation tree
that is first-class, not reconstructed from application logs.

---

## Proposal 1: Bi-Temporal Fact Model

### Problem

`fact.timestamp = Process.clock_gettime(CLOCK_REALTIME)` records the moment the
fact was written to the store. This is transaction time. But business facts have
their own time: when did this event actually occur in the real world?

The `term` field exists but carries no defined semantics. Nothing writes it
meaningfully.

Without two time axes you cannot answer:

```text
"What was the technician's availability on 2026-04-01,
 based only on information we had as of 2026-04-03?"
```

That is a standard scheduling, auditing, and dispute-resolution question.
A single timestamp cannot serve it.

### Proposal

Define two explicit time axes on every Fact:

| Field | Meaning | Owner | Type |
|---|---|---|---|
| `transaction_time` | When the fact was committed to the store | Store (auto-set) | Float (wall-clock epoch) |
| `valid_time` | When the event is asserted to be true in the domain | Writer (optional) | Float (epoch), nullable |

Rename the current `timestamp` field to `transaction_time`.
Repurpose the current `term` field as `valid_time` (nullable Float).

Important: `transaction_time` should remain a wall-clock epoch float, not a
process monotonic clock. Persisted facts must be comparable across process
restarts and machines. A separate logical commit sequence can be added later if
we need total ordering under high concurrency:

```text
transaction_time  # wall-clock audit time
commit_seq        # optional logical sequence, future work
```

Wire compatibility: `term` was always written as `0` or left nil. Renaming it
to `valid_time` with nil-default is a clean break with no production loss.

### Query shape

```ruby
# What we know right now about what was true on 2026-04-01
store.read(store: :orders, key: "order-1", valid_as_of: Date.new(2026, 4, 1))

# What we knew on 2026-04-03 about what was true on 2026-04-01
store.read(
  store: :orders,
  key:   "order-1",
  valid_as_of:       Date.new(2026, 4, 1).to_time.to_f,
  transaction_as_of: Date.new(2026, 4, 3).to_time.to_f
)
```

### Writer API

```ruby
store.write(
  store:      :orders,
  key:        "order-1",
  value:      { status: :confirmed },
  valid_time: Time.utc(2026, 4, 1, 9, 0, 0).to_f  # optional
)
```

When `valid_time` is nil the query treats `valid_time = transaction_time` for
backward compatibility.

### Native implication

This is a real P0 native parity change, not a cosmetic Ruby-only alias. The
native extension currently stores `term` as `i64`; `valid_time` needs nullable
Float semantics. Do not hide `valid_time` in the value hash unless we explicitly
decide to defer the breaking native migration. The preferred pre-v1 move is to
change the fact struct once and keep Ruby/native/wire parity.

---

## Proposal 2: Embedded Derivation on Fact

### Problem

Provenance is split across two stores: the snapshot fact and a separate receipt
fact. Answering "why does this fact exist?" requires two round-trips. For
derived facts this is always two stores, always two reads.

```ruby
snap    = store.history(store: :availability_snapshots, key: k).last
receipt = store.history(store: :derivation_receipts, key: snap.id).last
# only now do we know the source_fact_ids and derivation name
```

The receipt store becomes load-bearing infrastructure. Loses of it make derived
facts unexplainable.

### Proposal

Add a `derivation` field to Fact. It is nil for base facts and populated for
derived facts.

```ruby
Fact = Struct.new(
  :id,
  :store,
  :key,
  :value,
  :value_hash,
  :causation,
  :transaction_time,   # renamed from timestamp
  :valid_time,         # renamed from term
  :schema_version,
  :producer,
  :derivation,         # NEW — nil for base facts
  keyword_init: true
)
```

`derivation` shape:

```ruby
{
  name:               "availability_snapshot",
  version:            "1.0",
  descriptor_fact_id: "uuid-rule-v1",
  source_fact_ids:    ["uuid-a", "uuid-b", "uuid-c"],
  source_hash:        "optional-stable-source-digest"
}
```

`descriptor_fact_id` is important: source facts explain the data inputs, while
the descriptor fact explains the rule/version that interpreted those inputs.

### Result

`explain(fact)` becomes O(1):

```ruby
fact.derivation[:source_fact_ids]  # => ["uuid-a", "uuid-b", ...]
fact.derivation[:name]             # => "availability_snapshot"
```

The external receipt store becomes optional audit redundancy for successful
derived facts, not the only provenance path.

Keep receipts anyway. Inline `derivation` answers "why does this successful
fact exist?" Receipts answer "what did the evaluator do?", including no-op,
rejected, invalid, superseded, or failed evaluations where no derived fact may
exist.

### Migration

`derivation` is nil for all existing base facts. No existing reads break.
Writers that use `AvailabilityLedger` or any future derivation path pass
`derivation:` to `store.write`. Base fact writers pass nothing.

---

## Proposal 3: Typed Producer Reference

### Problem

`producer` is an untyped hash with no schema:

```ruby
fact.producer  # => { "system" => "availability_ledger", "version" => "1.0" }
# or nothing, since native extension does not persist it (known Phase 2 gap)
```

You cannot query "all facts produced by derivations" or "all facts from external
API ingestion" without scanning every fact's value.

### Proposal

Define a typed producer schema. Producer is a Hash with a required `type` field:

```ruby
# Derivation-produced fact
{ type: :derivation, name: "availability_snapshot", version: "1.0" }

# Contract-produced fact
{ type: :contract, contract_id: "BookingWorkflow", run_id: "run-abc" }

# External ingestion
{ type: :external, source: "crm_api", client_id: "spark-prod" }

# Human / operator
{ type: :operator, user_id: "alex@example.com" }

# Store-internal (cascades, triggers)
{ type: :system, subsystem: "changefeed" }
```

Typed producer enables:

```ruby
store.history(store: :x, producer_type: :derivation)
store.history(store: :x, producer_type: :external, producer_source: "crm_api")
```

These become indexable at the storage layer once Rust parity for `producer`
lands (rust-native-data-plane Priority 0).

### Fix required now

`Fact#producer` must be persisted by the native extension. This is listed as
Phase 2 in the current native baseline. It should be promoted to Priority 0
because typed producer is a foundational query axis.

---

## Proposal 4: Key Schema in Descriptor

### Problem

Composite keys are encoded as flat strings by convention:

```ruby
"tech-1/2026-05-04/5d"
```

There is no way for the store to know the structure of a key. You cannot query
"all snapshots for technician tech-1 regardless of horizon" without a full scan
plus application-level string parsing.

### Proposal

Descriptors can declare a `key_schema` as an ordered list of named segments:

```ruby
store.register_descriptor({
  kind:       :store,
  store:      :availability_snapshots,
  key_schema: [:technician_id, :horizon_start, :horizon_days_bucket]
})
```

The wire format for the key remains a plain string (`"tech-1/2026-05-04/5d"`).
Key schema is store-level metadata that the query layer uses to:

- parse and validate keys on write
- enable prefix queries: `store.query(store: :x, key_prefix: { technician_id: "tech-1" })`
- build per-segment indexes in the Rust data plane

This is a non-breaking additive change. Descriptors without `key_schema` work
exactly as today. Key schema is advisory at first, enforced when a conformance
spec is added.

---

## Proposal 5: Registered Derivation Descriptor As Fact

### Problem

"Bounded derivations can run near storage" is the strongest of the three
criteria, and it is currently not realised. The flow today is:

```text
app code calls store.write(...)
  → fact persisted
  → app code manually calls compute_snapshot(...)
  → derived fact persisted
```

The store is passive. The app is the orchestrator. This means:

- derived state is only up to date if the app remembers to call the derivation
- derivation logic lives in application code, not in the store
- replay of the store does not automatically reconstruct derived state
- there is no way to inspect which business rules are active in the store at a
  given point in time

### Claim

A Derivation Descriptor fact is storage-level declarative behavior.

```text
store.write(source_fact)
  → store checks registered Derivation Descriptors for this store
  → matching descriptor evaluated by Derivation Evaluator
  → derived fact written (with producer: { type: :derivation, name:, version: })
  → derivation receipt written (or embedded in fact.derivation)
```

The store becomes active in a narrow sense: it can host deterministic registered
derivation evaluators and write derived facts. It must not become a general
application workflow engine.

### Derivation Descriptor as a fact

A Derivation Descriptor is not application code. It is a data packet stored in
the store itself, in a reserved `:_derivation_descriptors` store:

```ruby
store.write(
  store: :_derivation_descriptors,
  key:   "availability_snapshot/1.0",
  value: {
    kind:    :derivation,
    name:    "availability_snapshot",
    version: "1.0",
    inputs:  [
      { store: :availability_templates,  key_by: :technician_id },
      { store: :availability_overrides,  key_prefix: :technician_id },
      { store: :order_events,            filter: { technician_id: "$technician_id" } }
    ],
    output:  {
      store: :availability_snapshots,
      key:   "$technician_id/$horizon_start/$horizon_days_bucket"
    },
    rule_ref: "Igniter::Store::IntelligentLedger::AvailabilityDeriver/1.0"
  }
)
```

`rule_ref` points to a Ruby class registered with the store. The class is not
serialised (that would be arbitrary code execution). The reference is.

This means:

- descriptors are versioned, superseded, and audited exactly like any other fact
- a new descriptor version = new fact in `:_derivation_descriptors`
- replay reconstructs which descriptor was active at time T
- `explain(derived_fact)` returns descriptor + source_fact_ids from
  `fact.derivation`

Boundary:

```text
Allowed:
  registered deterministic derivation evaluators
  bounded rule packets
  derived facts
  evaluation receipts

Not allowed:
  arbitrary Ruby from persisted facts
  app callbacks with side effects
  external API calls from store derivation execution
  workflow orchestration hidden inside storage
```

### Relationship to existing Reactive Derivations plan

`reactive-derivations-plan.md` describes the evaluator mechanics. This proposal
adds the framing: **the descriptor is a fact, not a configuration object**. This
is the key difference from a Rails callback or an ActiveRecord observer. The
derivation rule is part of the ledger history.

---

## Proposed Fact Struct (post-changes)

```ruby
Fact = Struct.new(
  :id,               # String UUID
  :store,            # Symbol
  :key,              # String
  :value,            # Hash (symbol keys, native-normalised)
  :value_hash,       # String SHA256
  :causation,        # String UUID or nil (previous fact ID for same key)
  :transaction_time, # Float (wall-clock epoch, auto-set by store)
  :valid_time,       # Float (domain time, writer-supplied, nullable)
  :schema_version,   # Integer
  :producer,         # Hash { type:, name:, ... } or nil
  :derivation,       # Hash { name:, version:, descriptor_fact_id:, source_fact_ids: } or nil
  keyword_init: true
)
```

Two field renames: `timestamp → transaction_time`, `term → valid_time`.
Two field additions: `derivation` (inline provenance), `producer` (typed).

---

## Implementation Order

These proposals are ordered by leverage: changes to Fact struct become more
expensive every week as the protocol, native extension, specs, and downstream
code accumulate.

| Priority | Proposal | Why first |
|---|---|---|
| P0 | Rename `timestamp → transaction_time`, `term → valid_time` | Wire format change, cheapest now |
| P0 | Add `derivation` field to Fact struct | Struct change, grows cheaper to do together with rename |
| P0 | Fix `Fact#producer` in native extension | Blocks P1; currently Phase 2 gap |
| P0 | Compatibility aliases `timestamp` and `term` | Keeps current call sites green during transition |
| P1 | Typed producer schema + producer_type index | Requires native producer fix |
| P1 | `key_schema` in descriptor + prefix query | Additive, non-breaking |
| P2 | Derivation Descriptor as fact + reactive evaluator | Requires changefeed backbone first |
| P3 | Bi-temporal query API (valid_as_of + transaction_as_of) | Requires valid_time field (P0) |

P0 items should be done together in a single breaking-change commit before any
further slices build on the current Fact struct.

---

## Non-Goals

- No full Datalog or Prolog runtime.
- No arbitrary Ruby execution from persisted descriptor packets (`rule_ref`
  names a registered class, it does not serialize a lambda).
- No general application workflow execution inside the store.
- No external side effects from derivation evaluators.
- No distributed transactions or cross-store consistency guarantees.
- No general purpose query planner in this proposal.
- No stable DSL promise before v1.
- No time-zone awareness in `valid_time` (UTC floats only).

---

## Open Questions

- Should `derivation` be a top-level field or nested under `producer`?
  Argument for nesting: a derived fact has `producer: { type: :derivation, ... }`
  and the source IDs live there too. Argument against: producer is about who
  produced the fact; derivation is about what produced the value. They are
  different concerns.
- Do we need a future `commit_seq` field for total ordering independent of
  wall-clock time?
- Should superseded derived facts be marked with a tombstone fact or inferred by
  latest-key semantics (current approach)?
- When `rule_ref` points to a Ruby class that is no longer loaded, what happens
  during replay? Soft fail (emit no-op receipt) or hard fail (raise)?
- Should the `:_derivation_descriptors` store be a reserved name in the protocol
  or a configuration option?
