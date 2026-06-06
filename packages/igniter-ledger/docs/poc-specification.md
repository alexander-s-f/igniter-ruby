# Contract-Native Store: POC Specification

Status date: 2026-04-29.
Scope: Ruby POC proving the core storage model. Not a public API.
Source: `examples/store_poc.rb` — runnable, stdlib only.
Package POC: `packages/igniter-ledger` — isolated gem skeleton for continued
experiments.
Russian companion: `poc-specification.ru.md`.

---

## What This POC Proves

Five claims that must hold before any further design work:

| Claim | Proved by |
|-------|-----------|
| Content-addressed facts give free deduplication | Section 8 of the demo |
| Time-travel is structural, not a bolt-on feature | Section 4 |
| Causation chain is intact across writes | Section 2 + 5 |
| Reactive invalidation reaches agents without polling | Section 6 |
| File-backed WAL survives process restart | Section 9 |

Compile-time access path registration is also demonstrated (Section 1), but
its full value becomes apparent only when the compiler generates paths
automatically from `store_read` declarations.

---

## Architecture

```
   Contract DSL (store_read / store_write)
          │ register_path (at load time)
          ▼
   ┌─────────────────────────────────────────────┐
   │              IgniterStore (facade)           │
   │                                             │
   │  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
   │  │ FactLog  │  │ReadCache │  │SchemaGraph│  │
   │  │ (WAL)    │  │(projns)  │  │(paths)    │  │
   │  └────┬─────┘  └────┬─────┘  └────┬──────┘  │
   │       │             │              │         │
   │       │             └──────────────┘         │
   │       │         invalidate + push             │
   └───────┼─────────────────────────────────────┘
           │ (optional)
      FileBackend (JSON-Lines WAL)
```

**FactLog** — append-only truth. Never mutates. Holds all facts since
process start (or since last replay from file).

**ReadCache** — projection layer. Caches current-read results keyed by
`[store, key, as_of]`. Cleared on write; pushes invalidation signals to
registered consumers (agents, projections).

**SchemaGraph** — compile-time registry. Access paths are written here
at contract class-load time. The store knows who reads what before any
data exists.

**FileBackend** — optional persistence. JSON-Lines WAL: one Fact per
line, opened in append mode with `sync=true`. On restart, replays all
lines to rebuild in-memory indexes.

---

## Core Data Model

### Fact

```ruby
Fact = Struct.new(
  :id,             # String   — SecureRandom.uuid
  :store,          # Symbol   — which Store[T] or History[T]
  :key,            # String   — identity within the store
  :value,          # Hash     — the payload (deeply frozen)
  :value_hash,     # String   — SHA-256 of stable-serialized value
  :causation,      # String?  — value_hash of previous fact for this key
  :timestamp,      # Float    — Process.clock_gettime at write time
  :term,           # Integer  — Raft term (0 = standalone)
  :schema_version, # Integer  — which contract schema produced this
  keyword_init: true
)
```

**Stable serialization** sorts Hash keys before hashing. Hash insertion
order never affects `value_hash`. This guarantees that two facts with
the same logical content always share the same content address.

**Causation** links facts into a per-key linked list:

```
write key="r1" {status: :open}   → Fact f1 (causation: nil)
write key="r1" {status: :closed} → Fact f2 (causation: f1.value_hash)
```

Following `causation` backward from any fact reconstructs the complete
mutation history for that key without a full log scan.

### AccessPath

```ruby
AccessPath = Struct.new(
  :store,      # Symbol        — store name
  :lookup,     # Symbol        — :primary_key | :scope | :filter
  :scope,      # Symbol?       — named scope (:open, :pending, …)
  :filter,     # Hash?         — field → input-node binding
  :cache_ttl,  # Integer?      — seconds; nil = no TTL
  :consumers,  # Array<#call>  — invalidation callables
  keyword_init: true
)
```

Registered once per `store_read` declaration when the contract class is
loaded. The store pre-indexes on this information; at runtime the access
path is already resolved.

---

## Write Path

```
store.write(store: :reminders, key: "r1", value: { … })

  1. Fetch latest Fact for [store, key] from FactLog
  2. Fact.build: stable-serialize value → SHA-256 → causation chain
  3. FactLog.append (in-memory + optional FileBackend.write_fact)
  4. ReadCache.invalidate(store, key)
     → deletes current cache entries for this key
     → calls every registered consumer: agent_mailbox.call(:reminders, "r1")
  5. Return the new Fact
```

For `History[T]` (append-only), the key is a fresh `SecureRandom.uuid`
per event. There is no "latest version" — every append is a root fact
with `causation: nil`.

```
store.append(history: :reminder_logs, event: { action: :created })
  → Fact(key: uuid, causation: nil)   ← independent root each time
```

---

## Read Path

### Current read

```
store.read(store: :reminders, key: "r1")

  1. ReadCache.get([store, key, nil], ttl:)   → cache hit? return value
  2. FactLog.latest_for(store, key)           → scan @by_key, take last
  3. ReadCache.put([store, key, nil], fact)   → cache for next call
  4. Return fact.value
```

### Time-travel read

```
store.time_travel(store: :reminders, key: "r1", at: t_mid)

  1. ReadCache.get([store, key, t_mid])       → likely miss (first call)
  2. FactLog.latest_for(store, key, as_of: t_mid)
     → filters @by_key to facts where timestamp <= t_mid → takes last
  3. ReadCache.put([store, key, t_mid], fact) → immutable; never invalidated
  4. Return fact.value
```

Time-travel results are cached under `as_of: Float` keys. They are never
invalidated by future writes — a past state cannot change.

---

## Reactive Invalidation

When a `store_write` fires, `ReadCache.invalidate` does two things:

1. Removes current-read cache entries for `[store, key]`.
2. Calls every consumer registered under `store` with `(store, key)`.

Consumers are any `#call`-able: a lambda, a method, an agent's `receive`
wrapper. This is the mechanism that lets `ProactiveAgent` stop polling:

```ruby
# At contract load time:
store.register_path(AccessPath.new(
  store:     :tasks,
  lookup:    :scope,
  scope:     :pending,
  cache_ttl: 30,
  consumers: [agent.method(:on_store_invalidated)]
))

# At runtime, when :tasks changes:
# store → cache.invalidate(:tasks, key) → agent.on_store_invalidated(:tasks, key)
# Agent re-resolves its :tasks dependency without polling.
```

---

## File Backend

`FileBackend` is a minimal JSON-Lines WAL. Each line is one Fact
serialized with `fact.to_h`. The file is opened once in append mode;
`sync=true` ensures durability without explicit `fsync` calls per write.

**Replay** reads all lines on `IgniterStore.open(path)` and feeds each
Fact into `FactLog.replay` (which bypasses the backend write, avoiding
re-appending replayed facts to the file).

**Limitations of the POC backend:**
- No compaction (file grows forever)
- JSON key round-trip converts symbols to strings (noted in source)
- No CRC or length-prefix framing (truncated line = silent data loss)
- Single-file; no segmented rotation

These are known simplifications. A Rust rewrite would use a binary
framed format (e.g., length-prefixed MessagePack or a custom
LSM-compatible record format).

---

## Demo Output (verified)

```
1. Setup
Access paths for :reminders: 1

2. Write path
f1 hash:      efee04502dcdf4f8...
f1 causation: nil  (nil = root)
f2 hash:      9df97bfc5097b37a...
f2 causation: efee04502dcdf4f8...  (← f1.value_hash)
Chain intact: true

3. Current read
Current status: :closed

4. Time-travel
Status at t_mid:          :open     ← state before second write
Status at t_after:        :closed
Status before any write:  nil

5. Causation chain
[0] hash=efee04502dcd  causation=nil
[1] hash=9df97bfc5097  causation="efee04502dcd"

6. Reactive invalidation
Invalidation events: [[:reminders, "r1"], [:reminders, "r1"]]

7. History
Log entries: [:created, :closed]
Events since t_mid: [:created, :closed]

8. Deduplication
fa.value_hash == fb.value_hash: true
Order-independent hash:          true

9. WAL replay
Written 2 facts; replayed after restart — done: true
Fact count after replay: 2
```

---

## What the POC Does Not Prove Yet

| Capability | Status | Next step |
|------------|--------|-----------|
| Compiler-generated access paths | Manual in demo | Wire into DSL compiler |
| Distributed consensus replication | Stub (term=0) | Use existing `Igniter::Consensus` |
| Scope / filter queries | Not implemented | Extend `FactLog.facts_for` |
| Schema coercion on read | Not implemented | Thread B / D from research doc |
| Projection auto-maintenance | Not implemented | Incremental dataflow hook |
| TTL-aware cache eviction | Implemented; not tested at scale | Benchmark |
| Concurrent write safety | MonitorMixin; not stress-tested | Concurrent::Map or Ractors |

---

## Rewrite Targets (Rust / C)

If the model proves sound after real application pressure, the following
components are the primary rewrite candidates:

**FactLog** — the hot path. Replace `Array + Hash` with an LSM-tree
(RocksDB-style) for write performance and a memory-mapped read tier for
O(1) key lookup. The causation chain maps naturally to an LSM value log.

**FileBackend** — replace JSON-Lines with a binary framed format:
4-byte length prefix + MessagePack body + CRC-32 trailer. Add segment
rotation and a Bloom-filter-based compaction pass.

**ReadCache** — replace `Hash + MonitorMixin` with a
sharded `DashMap` (Rust) or `concurrent-ruby`'s `ConcurrentHash`. Add a
proper LRU eviction policy with configurable capacity.

**SchemaGraph** — read-heavy, write-rare (populated at load time only).
A flat array of `AccessPath` structs sorted by `store` is sufficient;
binary search replaces the hash lookup. Trivially portable to C.

**content addressing** — SHA-256 is already fast; replace with BLAKE3 in
Rust for ~3× throughput at the same security level.

The Ruby facade (`IgniterStore`) can remain in Ruby as a thin FFI wrapper
over a Rust/C dylib, preserving the zero-dependency constraint for the
core gem.

---

## Reference

- [Contract-Native Store Research](./research/store-iterations.md)
- [Contract Persistence Organic Model](../../../docs/research/contract-persistence-organic-model.md)
- [POC source](../examples/store_poc.rb)
- [POC package](../README.md)
