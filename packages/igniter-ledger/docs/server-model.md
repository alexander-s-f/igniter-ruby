# Contract-Native Store: Server Model & Transport Architecture

Status date: 2026-04-30.
Audience: Architect Supervisor, Package Agent, Research.

---

## Context

`igniter-ledger` started as an embedded POC — app + storage in a single process.
That works for demos and single-node deployments, but it creates a hard constraint:
the store lives and dies with the app process.

The architectural question we explored: **how should the store grow when the app
scales beyond one process, or when data sources are external (IoT sensors, event
streams, remote services)?**

---

## The Projection Model

The core idea: the app does not embed the store. Instead it **deploys its contract
to the server**, which becomes a projection host.

```
App process                 Store Server
──────────────────          ──────────────────────────
Contract definition  ─────► Contract Registry
                             │
Runtime computation          │  (stores hold immutable facts,
(stays in app)               │   serves scopes + replay)
                             │
                     ◄────── Fact reads (scope/replay/causation)
```

Key properties:
- **Computations remain in the app.** The server does not evaluate contract nodes.
- **The server is the durable fact store.** It persists WAL, manages checkpoints,
  serves queries.
- **The interface is data, not callbacks.** App sends `write`/`append` calls;
  server replies with facts. No RPC for logic.

---

## Event Delivery Model

Server writes events — it does not decide who receives them or how.
Delivery is the **user's responsibility**, wired via DSL adapters:

```ruby
# App-side subscription declaration
store.on_scope(Task, :open) do |adapter(:webhook, url: "https://myapp.com/tasks")|
  # adapter handles delivery; server fires event → adapter takes over
end

store.on_scope(Task, :open, adapter: :queue, queue: "task-changes")
store.on_scope(SensorReading, :recent, adapter: :sse, channel: "sensors")
```

**Event bus flow:**

```
Server: fact written
   └─► SubscriptionRegistry — finds matching SubscriptionRecords
         └─► Event Bus
               ├─► WebhookAdapter    (HTTP POST, retry)
               ├─► QueueAdapter      (SQS / Sidekiq / Kafka)
               ├─► SSEAdapter        (Server-Sent Events / WebSocket)
               └─► (user-defined adapter)
```

The server writes to its event log and returns. Delivery is async and pluggable.
The `on_scope` call becomes a persistent `SubscriptionRecord` (not a Ruby Proc)
when a network backend is in use.

---

## Deployment Topologies

The key insight: these are not different products — they are different **backend
configurations** of the same `Companion::Store` facade. The app code does not change.

### 1. Embedded (current default)

```
[App + IgniterStore]
```

- Backend: `:memory` or `:file`
- Single process; zero network overhead
- Works today; good for demos, single-node, dev

### 2. Local Server (IPC)

```
[App Process] ──unix socket──► [IgniterStore Server Process]
```

- Backend: `:network, transport: :unix`
- Same machine; sub-millisecond latency
- App crashes without losing store state

### 3. Shared Cluster

```
[App 1] ──► [Store Cluster (primary + replicas)]
[App 2] ──►      │
[App N] ──►      └─► WAL replicated via replication log
```

- Backend: `:network, transport: :tcp, address: "store.internal:7400"`
- Multiple app instances share one projection
- Strong consistency via quorum writes (for `:strong` stores)

### 4. Edge / IoT

```
[Sensor Node]
   └─► local IgniterStore (accepts immediately, `:eventual`)
         └─► async replication ──► Central Store
```

- Local store accepts writes without coordination
- Replication is background and conflict-free (grow-only set semantics)
- Central store merges via union (CRDT)

---

## CRDT-Compatible Facts

Igniter facts are **immutable and content-addressed**:
- Each fact has a UUID `id` and a `value_hash` (BLAKE3 of stable-sorted JSON)
- Facts are never updated — a new write creates a new fact with a new id
- The FactLog is a **grow-only set**: `merge(A, B) = A ∪ B`

This means:
- No write conflicts (two nodes can both append; union is always consistent)
- Gossip replication is safe: exchange fact sets, merge by union
- No Raft needed for eventually-consistent stores
- Time-travel and causation chains are preserved across merges

The **causation chain** (`fact.causation = prior_fact.id`) survives replication
unchanged — it is content-addressed and immutable.

---

## Consistency Annotation

Not all stores need the same consistency guarantee.
Per-store annotation at definition time:

```ruby
# Strong: quorum write before ack (financial records, audit log)
store.register(Transaction, consistency: :strong)

# Eventual: local accept + async replication (sensor readings, telemetry)
store.register(SensorReading, consistency: :eventual)
```

Consistency is a **property of the schema**, not the connection.
The network backend routes writes accordingly:
- `:strong` → wait for quorum ack before returning
- `:eventual` → local write + enqueue replication → return immediately

---

## Recommended Implementation Order

### Phase 1 — Transport abstraction

Introduce `LedgerNetworkBackend` as a third backend alongside `:memory` and `:file`.

```ruby
# No app changes needed — swap the backend:
store = Igniter::Companion::Store.new(
  backend: :network,
  transport: :tcp,
  address:   "store.internal:7400"
)
```

The `LedgerNetworkBackend` serializes `write_fact` / `replay` / `write_snapshot` calls
over the transport. The server side is a minimal store-server process.

This is the **minimum viable step** that unlocks all topologies without changing
the `Companion::Store` facade.

### Phase 2 — SubscriptionRegistry

Move `on_scope` subscriptions from in-process Ruby Procs to persistent
`SubscriptionRecord` objects stored in the server.

```ruby
SubscriptionRecord = Struct.new(:store, :scope, :adapter, :config)
```

The server's event bus reads `SubscriptionRegistry` after each write and fires
delivery adapters.

### Phase 3 — Replication log

Add an append-only `ReplicationLog` alongside the WAL. Each fact write is also
posted to the replication log. A background `ReplicationWorker` reads the log
and fans out to replica nodes. Replicas apply facts via `FactLog#replay` (no
backend write — WAL belongs to primary).

### Phase 4 — Consistency annotation

Wire `consistency:` store metadata through to the network backend's write path.
`:strong` writes block until quorum ack; `:eventual` writes return after local
commit.

---

## What Stays in Ruby / App

Even with a full cluster deployment:

| Concern | Location |
|---------|----------|
| Contract node evaluation | App process |
| DSL (input/compute/output) | App process |
| Scope/history schema definition | App process |
| Adapter wiring (`on_scope`) | App process (DSL) |
| Fact storage, WAL, snapshot | Store server |
| Scope index | Store server |
| Event bus + delivery | Store server |
| Replication | Store server → replicas |

The app is always a **writer and reader**; it never becomes a passive client.
The store server is always a **durable projection host**; it never evaluates logic.

---

## Open Questions

1. **Protocol format**: JSON-over-TCP vs MessagePack vs gRPC.
   Current WAL uses CRC32-framed MessagePack — reuse for transport is natural.

2. **Auth**: mTLS for server-to-server; API key or token for app-to-server.
   Out of scope for Phase 1 (localhost-only transport first).

3. **Back-pressure**: what happens when the replication log grows faster than
   replicas consume? Need a bounded queue or flow control signal.

4. **Snapshot replication**: replicas need to bootstrap from a snapshot, not
   replay the full WAL. `write_snapshot` already exists — reuse for replica
   bootstrapping.

5. **Schema registry**: with multiple app instances, how do coercion hooks and
   schema versions stay consistent? Long-term: server holds schema registry;
   apps register on connect.

---

## Relation to Existing Code

- `FileBackend` — already has CRC32-framed WAL + snapshot. `LedgerNetworkBackend` will
  reuse the framing format for its wire protocol.
- `FactLog#all_facts` — used by `checkpoint`; also needed for snapshot
  replication bootstrapping.
- `CoercedFact` / `register_coercion` — in Phase 2+, coercions may migrate to
  server-side schema registry.
- Playground demo 05 (snapshot) and 06 (concurrency) are direct precursors to
  replication and cluster behaviour.
