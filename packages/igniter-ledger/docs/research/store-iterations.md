# Contract-Native Store: Research Iterations

Status date: 2026-04-29.
Format: living research document — each iteration appended below.
Scope: distributed proactive agent clusters; optional separate package.
Canonical: this file. Russian companion: `store-iterations.ru.md`.

---

## Iteration 0 — Constraints and Decisions

*Recorded from design session, 2026-04-29.*

These constraints bound the research and are not re-opened without cause.

### Target context

Igniter Application / Cluster layer. The primary consumer is an application
running decentralized, distributed, proactive agents. The store must serve
agents that:

- react to data changes proactively (not polled from outside)
- are distributed across a cluster
- need consistent shared state without coordination overhead
- need to reason about historical state (what happened before event Y?)

### Boundary with external databases

We do not forbid developers from using their preferred database. We provide a
minimal coupling API; everything beyond that is the developer's responsibility
to implement in their own intermediate layer. If the native store proves better
in practice, it sells itself. No forcing.

### Priority features

From all possible directions, two are prioritized:

1. **Compile-time query optimization** — access paths derived from the contract
   graph before any data exists, not at runtime.
2. **Time-travel** — every state queryable at any past point, as a structural
   consequence of immutability, not a bolted-on feature.

### Package scope

Optional, separate package (candidate name: `igniter-ledger`). Recommended but
not imposed. The product must justify itself on merit.

---

## Iteration 1 — Where Existing Systems Fall Short

*Recorded from design session, 2026-04-29.*

All existing storage systems are storage-first. Business logic lives outside:

```
Relational (PG, SQLite)  → tables   → ORM       → business logic (outside)
Document (Mongo)         → docs     → ODM       → business logic (outside)
Event stores (Kafka, ES) → events   → manual    → business logic (outside)
Datomic                  → facts    → Datalog   → business logic (outside)
Graph DB (Neo4j)         → nodes    → Cypher    → business logic (outside)
```

In every case the storage engine is blind to intent. It does not know why data
is read or what the data means in the domain.

Igniter is the first system where the **full dependency graph of business logic
is known at compile time**. This opens doors that are structurally closed to
every system above.

### The three gaps that matter most for distributed agents

**Gap 1 — Runtime query planning.**
SQL and every ORM derive the query plan at runtime. The engine sees the query
for the first time when it executes. In a contract, every `store_read` is a
typed compile-time dependency. The store can know the complete access pattern
before any data or query exists.

**Gap 2 — Projection maintenance is manual.**
In CQRS/ES, projections are hand-written consumers that rebuild read models
from events. In Igniter, projections are contracts. If the store understands
contracts, it can maintain projections automatically — incrementally, with
cache invalidation derived from the graph.

**Gap 3 — History is an afterthought.**
Datomic has time-travel, but it is a separate query mode (`as-of`, `history`).
In Igniter, `History[T]` is a first-class storage shape. An append-only fact
log is not an audit add-on; it is the write model. Current state is always a
projection of the history.

---

## Iteration 2 — Core Architecture Sketch

*Recorded from design session, 2026-04-29.*

### The synthesis: contracts + time-travel + distributed agents

The three priorities reinforce each other:

```
Compile-time graph  →  access paths known at deploy
                    →  store pre-indexes by contract, not by query
                    →  agents declare reads; store routes writes to relevant nodes

Append-only facts   →  every write is a new fact, nothing is mutated
                    →  time-travel is structural (scan facts where t <= T)
                    →  Raft consensus log IS the time axis

Content addressing  →  facts stored by hash of content (like Git objects)
                    →  structural sharing between versions is free
                    →  deduplication is automatic
                    →  causation chain links facts (previous_hash field)
```

### Fact model

Every `store_write` produces an immutable fact:

```
Fact {
  contract:      ReminderContract,        # which contract produced this
  store:         :reminders,              # which Store[T]
  key:           "uuid-123",              # identity within the store
  value_hash:    "sha256:abc...",         # content address of the value
  value:         { id: "...", ... },      # the actual payload
  causation:     "sha256:prev...",        # links to the previous fact for this key
  timestamp:     1714000000,              # wall-clock (for time-travel queries)
  term:          42,                      # Raft term (for distributed ordering)
  schema_hash:   "sha256:schema...",      # content address of the schema version
}
```

This one structure gives:

- **Time-travel**: `facts.select { |f| f.timestamp <= t && f.store == :reminders }`
- **Audit trail**: follow `causation` chain backward
- **Schema versioning**: `schema_hash` links each fact to the exact schema version that produced it
- **Distributed ordering**: `term` from Raft consensus resolves conflicts
- **Deduplication**: same content ⟹ same `value_hash`

### Compile-time access path generation

When a contract declares:

```ruby
store_read :reminder, from: :reminders, by: :id, using: :reminder_id,
           cache_ttl: 60, coalesce: true
```

The compiler emits:

```
AccessPath {
  store:          :reminders,
  lookup:         :primary_key,
  key_binding:    :reminder_id,
  cache_strategy: :ttl,
  cache_ttl:      60,
  coalesce:       true,
  consumers:      [ReminderContract, ReminderDetailProjection, ...]
}
```

The store reads this at deploy time and pre-builds the index. At runtime there
is no "plan this query" step — the path was materialized when the contract was
compiled.

### Data-locality for distributed agents

When `ProactiveAgent` declares:

```ruby
store_read :pending_tasks, from: :tasks, scope: :pending, cache_ttl: 30
```

The store knows at deploy time:

- `ProactiveAgent` reads `:tasks` with `:pending` scope
- cache is 30 s
- when `:tasks` changes, `ProactiveAgent`'s cache is the invalidation target
- if `ProactiveAgent` runs on Node A, replicate relevant `:tasks` changes to
  Node A with priority

This is **data-locality optimization derived from the contract graph** — not
possible with any ORM or query planner today.

### Internal store structure (candidate)

```
igniter-ledger/
  WriteStore     ← append-only fact log; WAL-backed; content-addressed values
  ReadStore      ← projections maintained by contract graph; live materialized views
  TimeIndex      ← timestamp + term index over the fact log (O(log n) time-travel)
  SchemaGraph    ← compile-time generated access paths from contracts
  ClusterSync    ← consensus replication using existing Igniter::Consensus (Raft)
  Adapter API    ← minimal coupling surface for external DBs (escape hatch)
```

### Relation to existing Igniter components

```
Igniter::Consensus  →  ClusterSync uses Raft log; log entries = facts
Igniter::NodeCache  →  ReadStore respects existing TTL + coalescing semantics
Igniter::AI::Agent  →  ProactiveAgent can subscribe to ReadStore projections
incremental dataflow →  projection maintenance is the incremental computation model
Saga / Effect       →  store_write failure triggers Saga compensation; fact is not committed
```

---

## Iteration 3 — Open Threads

*Recorded from design session, 2026-04-29. To be expanded in future iterations.*

### Thread A — Minimal Adapter API surface

What is the minimum interface a developer needs to wire an external DB?

Candidate shape:

```ruby
module Igniter::Store::Adapter
  # Called by store_read nodes at runtime (after compile-time path resolves)
  def read(store_key, lookup)     # → Fact or nil

  # Called by store_write nodes at app boundary
  def write(store_key, fact)      # → committed Fact

  # Called by store_append nodes (History[T])
  def append(history_key, fact)   # → appended Fact

  # Called by compile-time path builder at deploy time
  def build_access_path(path_descriptor)  # → void; implementation stores the index
end
```

Open: should `build_access_path` be optional (skip for simple adapters)?

### Thread B — Time-travel query API

What does a time-travel query look like from a contract?

Candidate DSL:

```ruby
store_read :reminder_at_t, from: :reminders, by: :id, using: :reminder_id,
           as_of: :query_time   # :query_time is an input node

# Or as a projection:
project :reminder_history, from: :reminders, key: :reminder_id,
        over: :all_time         # returns Array<Fact> ordered by timestamp
```

Open: should time-travel be a first-class DSL keyword or an option on
`store_read`? Should `as_of` accept a Raft term (for distributed consistency)
in addition to a wall-clock timestamp?

### Thread C — Contract as Query Language

Radical direction: the contract language IS the query language. No SQL, no
GraphQL. A read-only query contract declares its `store_read` dependencies; the
store executes them as a compiled query plan.

```ruby
class FindPendingTasksQuery < Igniter::Contract
  define do
    input  :agent_id
    store_read :tasks, from: :tasks, scope: :pending,
               filter: { assigned_to: :agent_id }
    compute :prioritized, depends_on: [:tasks], call: PrioritySort
    output :prioritized
  end
end
```

Open: is this worth pursuing in the native store, or is it a layer above the
store API?

### Thread D — Schema evolution without migration

When a contract field type changes from `:string` to `:integer`, the store
holds facts produced under both schema versions (tracked via `schema_hash`). A
coercion contract can bridge them:

```ruby
class ReminderContract::Coercion::V1toV2 < Igniter::Contract
  define do
    input  :fact_v1
    compute :coerced, depends_on: [:fact_v1], call: CoerceStatusField
    output :fact_v2
  end
end
```

Old facts are never rewritten. The read path runs the coercion contract
transparently when `schema_hash` does not match the current version.

Open: should coercion contracts be auto-generated from the field diff (migration
plan), or always hand-authored?

### Thread E — Reactive store for proactive agents

When an agent is proactive, it should not poll the store. The store should push
invalidation signals to agents whose `store_read` access paths cover changed
facts.

```
Fact written to :tasks (scope: :pending touched)
→ store inspects SchemaGraph: who has AccessPath on :tasks/:pending?
→ ProactiveAgent on Node A and Node B are subscribed
→ store pushes invalidation to both agents' mailboxes
→ agents re-resolve their :tasks dependency without polling
```

This fuses the existing `Igniter::AI::Agent` mailbox model with the store's
access path registry.

Open: push invalidation or push the new fact? Push to local node cache first,
then to remote agents?

---

## Next Iteration Candidates

Priority order (open to revision):

1. **Thread A** — nail down the minimal adapter API; this defines the escape
   hatch and bounds the native store scope
2. **Thread B** — define the time-travel query API; this is the highest-value
   differentiator
3. **Thread E** — reactive store + proactive agents; this is the primary use
   case and should shape the write path design
4. **Thread D** — coercion contracts / zero-migration evolution; builds on B
5. **Thread C** — contract-as-query-language; most radical, lowest urgency

---

## Iteration 4 — Thread E: Contract Query API Design

*Recorded from design session, 2026-04-29.*

### The question

Should `ArticleContract.find(title: "hello igniter")` exist on the class?
Three paths were considered:

- **A** — Arel-style class method (`ArticleContract.find(...)`)
- **B** — `Persistable` mixin/wrapper (separate class like `Contractable`)
- **C** — Queries declared in the contract body; no runtime query building

### Why Arel-style is wrong for Igniter

`ArticleContract.find(title: "hello igniter")` breaks three Igniter invariants:

1. **No compile-time validation** — the query is built at runtime; the
   compiler knows nothing about it.
2. **Store must be injected per-execution**, not held as a class-level
   singleton. A global `ArticleContract.store = my_store` is untestable
   and wrong in a cluster.
3. **The contract class becomes a hybrid** — schema + validator + query
   object simultaneously. These concerns should not merge.

### Why `Persistable` is the wrong abstraction level

`Persistable` solves the right problem ("not all contracts are persistent")
but at the wrong level. The opt-in is the `persist` declaration inside the
contract body. A contract with `persist` gets a store surface; a contract
without it has none. A separate wrapper module adds indirection without adding
clarity.

### The correct model: queries ARE contracts

A query in Igniter is a contract with `input` nodes and `store_read`
dependencies. The `query` macro declares a named mini-contract scoped to the
parent class. The compiler validates it at load time exactly like the main
`define` block.

```ruby
class ArticleContract < Igniter::Contract
  # Opt-in: only this contract has a store surface
  persist :articles, key: :id do
    field :id,     type: Types::UUID,   default: -> { SecureRandom.uuid }
    field :title,  type: Types::String
    field :status, type: Types::Symbol, default: :draft
    index :title
    scope :by_title,  where: { title: :title }
    scope :published, where: { status: :published }
  end

  # query = declared store_read contract; generates class-level sugar
  query :find_by_title do
    input  :title
    store_read :article, from: :articles, scope: :by_title
    output :article
  end

  query :published_articles do
    store_read :articles, from: :articles, scope: :published
    output :articles
  end

  # Time-travel — just another input, not a special mode
  query :article_at do
    input  :id
    input  :as_of
    store_read :article, from: :articles, by: :id, using: :id, as_of: :as_of
    output :article
  end

  # Business logic stays separate
  define do
    input :title
    input :status
    compute :validated, depends_on: %i[title status], call: ValidateArticle
    store_write :saved, from: :validated, target: :articles
    output :saved
  end
end
```

Usage — store is always injected per-call, never global:

```ruby
# Sugar generated from query declarations:
ArticleContract.find_by_title(title: "hello igniter", store: my_store)
ArticleContract.published_articles(store: my_store)
ArticleContract.article_at(id: "uuid-123", as_of: 3.days.ago.to_f, store: my_store)

# Under the hood — each is just a contract execution:
ArticleContract::Queries::FindByTitle.execute({ title: "hello igniter" }, store: my_store)
```

### Comparison

| | Arel / ActiveRecord | Igniter `query` |
|--|-----|------|
| Query validation | runtime | compile-time |
| Store scope | global singleton | per-call injection |
| Time-travel | separate API | `input :as_of` — ordinary input |
| Reactive invalidation | none | `store_read` → cache miss → agent push |
| Cache | separate config | `cache_ttl:` on `store_read` |
| Testing | mock ORM | `adapter: :memory` |
| "Not all contracts" | `include Persistable` | simply no `persist` block |

### Decision: A + B (deferred)

- **Primary path (A)**: only declared `query` blocks generate class-level
  methods. Any read must be declared. Compile-time validated. This is the
  target.

- **Complex cases (B)**: a standalone query contract without sugar, for
  queries that do not belong to a single contract class:

  ```ruby
  class FindDraftsByAuthor < Igniter::Contract
    define do
      input :author_id
      store_read :drafts, from: :articles,
                 filter: { author_id: :author_id, status: :draft }
      output :drafts
    end
  end
  ```

- **No Arel-style runtime query building.** Ever.

- **`query` macro implementation is deferred** until real application
  pressure justifies it. The model is decided; the sugar ships when needed.

### Key invariants preserved

- A contract without `persist` has zero store surface.
- Store is always injected per execution (`store:` keyword argument).
- Every query is a compiled graph; the compiler validates inputs, types,
  and `store_read` bindings at load time.
- Time-travel requires no special query mode — `as_of:` is an ordinary
  typed input.

---

## Iteration 5 — Thread B: Time-Travel DSL API

*Recorded from design session, 2026-04-29.*

### Three dimensions of time-travel

Time-travel is not one semantic but three distinct query shapes:

```
as_of:        Float | Integer  → "what was the state at T?"         — single value
since/until:                   → "show all versions between T1 and T2" — Array
after_fact:   String           → "state after a specific fact"        — causal
```

Return shape is orthogonal:

```
returns: :value           → payload Hash (default)
returns: :history         → Array<Hash> ordered by timestamp
returns: :fact            → raw Fact struct (full metadata, for audit)
returns: :causation_chain → [{value_hash, causation, timestamp}, ...]
```

### Decision: `as_of` is an option on `store_read`, not a separate keyword

```ruby
# NOT this (extra keyword pollutes DSL):
store_read_at :article, from: :articles, at: :query_time

# This — as_of as a parameter of store_read:
store_read :article, from: :articles, by: :id, using: :id, as_of: :query_time
```

`as_of:` accepts two types from the existing type system:

- **Float** → compared against `fact.timestamp` (wall-clock, standalone mode)
- **Integer** → compared against `fact.term` (Raft term, cluster mode)

The store determines the ordering mode from the value type. No new `TimePoint`
type is needed for the first iteration.

`after_fact:` accepts a **String** (value\_hash) for exact causal ordering in
distributed deployments where wall-clock is unreliable under clock skew.

### Full `store_read` signature with time-travel

```ruby
store_read :node_name,
  from:        :store_name,         # which Store[T]
  by:          :primary_key,        # :primary_key | :scope | :filter
  using:       :input_node,         # input node providing the key value
  scope:       :scope_name,         # for :scope lookup
  filter:      { field: :input },   # for :filter lookup

  # time-travel
  as_of:       :time_input,         # Float (wall-clock) | Integer (Raft term)
  since:       :from_input,         # range start (auto-implies returns: :history)
  until:       :to_input,           # range end
  after_fact:  :hash_input,         # String — value_hash of the causation point

  # return shape
  returns:     :value,              # :value | :history | :fact | :causation_chain
  schema:      :current,            # :current (coerce to current schema) | :as_stored (raw)

  # cache
  cache_ttl:   60,                  # ignored for time-travel (past is immutable)
  coalesce:    true
```

Compatibility rules:

| Combination | Result |
|---|---|
| `as_of:` | single value at T; immutably cached |
| `since:` + `until:` | auto `returns: :history` |
| `after_fact:` | single value after causation point; immutably cached |
| `returns: :causation_chain` | time constraints ignored; full chain |
| `as_of:` + `cache_ttl:` | `cache_ttl:` ignored; past never changes |

### Full example on ArticleContract

```ruby
class ArticleContract < Igniter::Contract
  persist :articles, key: :id do
    field :id,         type: :string
    field :title,      type: :string
    field :status,     type: :symbol, default: :draft
    field :body,       type: :string
    field :updated_at, type: :float,  default: -> { Time.now.to_f }
    index :title
    index :status
    scope :published, where: { status: :published }
  end

  # "What was this Article at time T?"
  # as_of: Float → wall-clock (standalone)
  # as_of: Integer → Raft term (cluster)
  query :article_at do
    input :id
    input :as_of   # Float | Integer — store selects ordering by value type
    store_read :article, from: :articles, by: :id, using: :id, as_of: :as_of
    output :article
  end

  # "State after a specific committed fact" — causal precision, not wall-clock
  # Required in distributed: wall-clock unreliable under clock skew
  query :article_after_fact do
    input :id
    input :fact_hash   # String — value_hash from a Fact
    store_read :article, from: :articles, by: :id, using: :id,
               after_fact: :fact_hash
    output :article
  end

  # "All versions between T1 and T2"
  query :article_versions do
    input :id
    input :from_time, type: :float, default: -> { (Time.now - 86_400 * 30).to_f }
    input :to_time,   type: :float, default: -> { Time.now.to_f }
    store_read :versions, from: :articles, by: :id, using: :id,
               since: :from_time, until: :to_time   # auto: returns :history
    output :versions   # Array<Hash>
  end

  # "Full mutation chain" — debugging and audit
  query :article_lineage do
    input :id
    store_read :chain, from: :articles, by: :id, using: :id,
               returns: :causation_chain
    output :chain   # [{value_hash:, causation:, timestamp:}, ...]
  end

  # "Raw fact as stored" — audit without schema coercion
  query :article_audit_snapshot do
    input :id
    input :as_of
    store_read :fact, from: :articles, by: :id, using: :id,
               as_of: :as_of, returns: :fact, schema: :as_stored
    output :fact   # Fact struct with value_hash, causation, schema_version
  end

  define do
    input :title
    input :body
    input :status
    compute :validated, depends_on: %i[title body status], call: ValidateArticle
    store_write :saved, from: :validated, target: :articles
    output :saved
  end
end
```

Usage — store always injected per-call:

```ruby
store = Igniter::Store::IgniterStore.new

# Current state
ArticleContract.execute({ title: "hello", body: "...", status: :draft }, store: store)

# Point-in-time, wall-clock
ArticleContract.article_at(id: "uuid-1", as_of: 3.days.ago.to_f, store: store)

# Point-in-time, Raft term (cluster)
ArticleContract.article_at(id: "uuid-1", as_of: 42, store: store)

# After a specific fact (causal — most precise)
ArticleContract.article_after_fact(id: "uuid-1", fact_hash: "sha256:abc...", store: store)

# History slice
ArticleContract.article_versions(id: "uuid-1",
                                  from_time: 7.days.ago.to_f,
                                  to_time:   Time.now.to_f,
                                  store: store)

# Causation chain
ArticleContract.article_lineage(id: "uuid-1", store: store)

# Audit snapshot without coercion
ArticleContract.article_audit_snapshot(id: "uuid-1", as_of: 3.days.ago.to_f, store: store)
```

### Cache behaviour for time-travel

```
as_of: nil    → current read   → cached as [store, key, nil]    → invalidated on write
as_of: Float  → time-travel    → cached as [store, key, as_of]  → NEVER invalidated
after_fact:   → causal read    → cached as [store, key, hash]   → NEVER invalidated
since/until   → history slice  → NOT cached (too large; use projections instead)
```

The past is immutable. `cache_ttl:` is ignored for time-travel reads; the
result is cached permanently once resolved.

### Deferred (not in first iteration)

| Question | Status |
|--------|--------|
| `Types::TimePoint` (unified clock type) | Deferred — Float/Integer sufficient now |
| Pagination for `:history` (`limit:`, `offset:`) | Deferred — application pressure |
| `schema: :as_stored` coercion contracts | Deferred — linked to Thread D |
| `since/until` caching via projections | Deferred — Thread E / incremental dataflow |
| Raft log index as third ordering primitive | Deferred — term is sufficient now |

---

## Iteration 6 — Thread D: Zero-Migration Schema Evolution via Coercion Contracts

*Recorded from design session, 2026-04-29.*

### The core problem

When a contract schema evolves, the store holds facts produced under multiple
schema versions simultaneously. Every Fact carries `schema_version: Integer`
(from the POC). Old facts are immutable — they must never be rewritten. The
read path must bridge old and new schema transparently.

### Change classification (reused from Companion)

The classification already proved in `WizardTypeSpecMigrationPlanContract`:

```ruby
def self.migration_status(added_fields, removed_fields, changed_fields)
  return :destructive if removed_fields.any?
  return :ambiguous   if changed_fields.any?
  return :additive    if added_fields.any?
  :stable
end
```

Mapped to coercion requirements:

| Change | Coercion needed | Auto-generated? |
|---|---|---|
| stable (no change) | no | — |
| additive (field added) | yes — inject default | **yes** |
| destructive (field removed) | yes — drop field | **yes** |
| ambiguous / type change | yes — transform value | **no** — hand-authored |
| rename (`:old` → `:new`) | yes — remap key | **no** — ambiguous |

### `schema_version` on the contract

Declared explicitly; developer increments when fields change:

```ruby
class ArticleContract < Igniter::Contract
  schema_version 2   # incremented from 1; triggers coercion path check
  ...
end
```

### `coercion` block DSL

Declared alongside the `persist` block it belongs to. Only ambiguous fields
need explicit declarations; additive and destructive are handled automatically.

```ruby
class ArticleContract < Igniter::Contract
  schema_version 2

  persist :articles, key: :id do
    field :id,     type: :string
    field :title,  type: :string
    field :status, type: :symbol, default: :draft  # v1: type was :string
    field :tags,   type: :array,  default: []      # v2: added
    index :status
    scope :published, where: { status: :published }
  end

  # Path: v1 → v2 (current)
  # auto: :tags (additive) → inject default []
  # hand: :status (ambiguous: string→symbol) → explicit lambda
  coercion :articles, from_version: 1 do
    field :status, via: ->(v) { v.to_sym }
    # :tags — automatic; default comes from persist block
  end

  # If v3 is declared later — add coercion from_version: 2
  # Chain: v1 → CoercionV1toV2 → v2 → CoercionV2toV3 → v3
end
```

Under the hood, each `coercion` block compiles to an anonymous contract —
consistent with "everything is a contract":

```ruby
# What the compiler generates from the coercion block above:
ArticleContract::Coercions::V1ToV2 = Igniter::Contract.define do
  input :raw_fact   # Fact struct

  compute :coerced, depends_on: [:raw_fact] do |raw_fact:|
    v = raw_fact.value.dup
    # hand-authored: status string → symbol
    v[:status] = v.fetch(:status, "draft").to_sym
    # auto-generated: tags additive, inject field default
    v[:tags]   = v.fetch(:tags, [])
    v
  end

  output :coerced
end
```

### Read path with transparent coercion

```
store_read :article, from: :articles, by: :id, using: :id
  ↓
1. Fetch latest Fact for [:articles, key]            — from FactLog
2. fact.schema_version == ArticleContract.schema_version?
   → yes : return fact.value directly
   → no  : look up coercion path in SchemaRegistry
3. Build coercion chain: v1 → V1ToV2 → v2 → V2ToV3 → v3 (current)
4. Execute chain (each step is a pure contract execution, no side effects)
5. Cache coerced result under [store, key, as_of, target_schema=current]
6. Return coerced value

The fact in the log is NEVER modified.
```

Cache key includes `target_schema_version` so that when the schema is bumped
again the previous coerced result is not served stale.

### Schema Registry

`SchemaGraph` (from the POC) is extended to a `SchemaRegistry`:

```ruby
SchemaRegistry = {
  articles: {
    current_version: 2,
    versions: {
      1 => { fields: { id: :string, title: :string, status: :string } },
      2 => { fields: { id: :string, title: :string, status: :symbol, tags: :array } }
    },
    coercions: {
      [1, 2] => ArticleContract::Coercions::V1ToV2
      # [2, 3] => ... when v3 is declared
    }
  }
}
```

The coercion path is the shortest path from `fact.schema_version` to
`current_version`. Linear chain in the common case; theoretically a DAG if
schema branches were merged. Linear chain only in the first iteration.

### Compile-time validation

At contract class-load time the compiler checks:

```
1. Collect all schema_versions recorded in SchemaRegistry for :articles
2. For each version N < current: is there a coercion [N, N+1]?
3. Missing path → WARN: "no coercion from v1 to v2 for :articles;
   store_read with schema: :current will fail at runtime for v1 facts"
4. Destructive change without :safe_to_drop annotation → WARN
```

Warning, not error — the store may not contain facts under the old version
(e.g. first deployment).

### Edge cases

**Rename:**

```ruby
coercion :articles, from_version: 1 do
  rename :name, to: :full_name   # explicit; developer resolves ambiguity
end
```

**Destructive with confirmation:**

```ruby
coercion :articles, from_version: 1 do
  drop :legacy_field, safe_to_drop: true
end
```

**Incompatible type with no safe default:**

```ruby
coercion :articles, from_version: 1 do
  field :status, via: ->(v) {
    %i[draft published archived].include?(v&.to_sym) ? v.to_sym : :draft
  }
end
```

### Zero-migration principle

No migration files. No `ALTER TABLE`. No data backfill.

```
Developer changes fields in persist block
→ increments schema_version
→ declares coercion block for ambiguous changes
→ deploys

In the store:
  old facts → schema_version: 1  (immutable forever)
  new facts → schema_version: 2
  read path → transparently coerces v1 → v2 on demand

No downtime. No scripts.
```

| | ActiveRecord migration | Igniter coercion |
|---|---|---|
| Schema change | migration file + ALTER TABLE | `schema_version N` + `coercion` block |
| Old data | backfill or NULL default | facts in log under old schema_version |
| Reading old data | direct (already migrated) | coercion chain on demand |
| Rollback | down-migration | schema immutable; chain works in reverse |
| Downtime | sometimes (lock on large tables) | none |
| Audit | data before migration lost | original facts preserved forever |

### Deferred

| Question | Status |
|--------|--------|
| SchemaRegistry implementation in store | Deferred — after query API is stable |
| Compiler enforcement of coercion paths | Deferred — requires compiler extension |
| Coercion chain performance (cache warm-up) | Deferred — benchmark first |
| Cross-contract coercion (shared Store[T]) | Deferred — not in scope yet |
| `schema: :as_stored` returning raw Fact | Linked to Thread B — already decided |

---

## Iteration 7 — Thread E: Reactive Store + Proactive Agents

*Recorded from design session, 2026-04-29.*

### Key insight: push trigger alongside the existing timer trigger

`ProactiveAgent` already works via a `_scan` mechanism:
timer fires `:_scan` → poll all watchers → evaluate triggers → act.

Thread E adds a **push trigger** next to the timer: when the store writes a
fact, it fires `:_scan` immediately instead of waiting for the next timer
cycle. Both paths use the same `_scan` pipeline; the store push is the primary
signal, the timer is the reliability fallback.

```
Pull (existing):
  timer(scan_interval) → :_scan → poll all watchers → evaluate triggers → act

Push (new):
  store.write → ReadCache.invalidate → consumer.call →
  → agent mailbox ← :_scan → poll store-backed watchers → evaluate triggers → act
```

### New `watch` form for store-backed dependencies

```ruby
# Existing form (poll lambda):
watch :pending_tasks, poll: -> { external_api.fetch_tasks }

# New form (store-backed, reactive):
watch :pending_tasks, store: :tasks, scope: :pending, cache_ttl: 30
```

At agent start, a store-backed watch registers an AccessPath with
`consumers: [method(:trigger_scan)]`. `trigger_scan` puts `:_scan` into the
agent mailbox immediately:

```ruby
def trigger_scan(store, key)
  mailbox.send(:_scan, { source: :store_push, store: store, key: key })
end
```

The poll lambda for a store-backed watch is auto-generated:

```ruby
# Compiled from watch :pending_tasks, store: :tasks, scope: :pending:
watch :pending_tasks, poll: -> { @store.read(store: :tasks, scope: :pending) }
```

The agent scan loop never changes — it always calls poll lambdas. The
only difference is *who initiates* the scan: timer or store.

### Full example: TaskDispatcherAgent

```ruby
class TaskDispatcherAgent < Igniter::Server::Agents::ProactiveAgent
  intent "Dispatch pending tasks as soon as they appear in the store"

  # Store-backed watch — push model
  # Any write to :tasks triggers an immediate scan instead of waiting
  watch :pending_tasks, store: :tasks, scope: :pending, cache_ttl: 30

  # Regular poll watch — unchanged
  watch :agent_config, poll: -> { Config.current }

  trigger :new_pending_tasks,
          condition: ->(ctx) {
            ctx[:pending_tasks]&.any? { |t| t[:dispatched_at].nil? }
          },
          action: ->(state:, context:) {
            undispatched = context[:pending_tasks].reject { |t| t[:dispatched_at] }
            undispatched.each { |task| dispatch(task) }
            state.merge(last_dispatch_count: undispatched.length)
          }

  # Long fallback interval — store push is the primary mechanism
  scan_interval 60.0

  private

  def dispatch(task) = ...
end

agent = TaskDispatcherAgent.start(store: my_store)
```

### Contract-level: `store_read reactive: true` and `tick`

For agents that use a contract as their scan logic:

```ruby
class PendingTasksContract < Igniter::Contract
  define do
    # reactive: true — when :tasks/:pending changes, notify the consumer
    store_read :tasks, from: :tasks, scope: :pending,
               cache_ttl: 30, reactive: true

    compute :prioritized, depends_on: [:tasks], call: PrioritizeByDeadline
    output :prioritized
  end
end

class TaskDispatcherAgent < Igniter::Server::Agents::ProactiveAgent
  # tick = contract is the agent's scan logic
  # Agent re-executes the contract on reactive invalidation
  tick PendingTasksContract, store: :companion_store

  on :tick_result do |result|
    next unless result.success?
    result[:prioritized].each { |task| schedule_work(task) }
  end

  scan_interval 120.0  # very long fallback; store push is primary
end
```

`tick` compiles to:
1. `watch :_tick_result, poll: -> { PendingTasksContract.execute({}, store: @store) }`
2. All `store_read reactive: true` nodes in the contract register consumers.
3. A trigger fires `:tick_result` when the result changes.

### Full flow: store write → agent action

```
1. store.write(store: :tasks, key: "t1", value: { status: :pending, ... })

2. FactLog.append(fact)

3. ReadCache.invalidate(store: :tasks, key: "t1")
   → delete cache entries for :tasks/"t1"
   → consumers for :tasks: [TaskDispatcherAgent(A).trigger_scan,
                              TaskDispatcherAgent(B).trigger_scan]

4. TaskDispatcherAgent(A).trigger_scan(:tasks, "t1")
   → mailbox.send(:_scan, { source: :store_push, store: :tasks, key: "t1" })

5. Agent thread: _scan handler fires
   → poll :pending_tasks (store.read :tasks, scope: :pending)
   → store: cache miss (just invalidated)
   → FactLog: latest fact + scope filter → [{ id: "t1", status: :pending, ... }]

6. Evaluate trigger :new_pending_tasks
   → condition: undispatched.any? → true

7. Action: dispatch(task)
   → state.merge(last_dispatch_count: 1)
```

### Distributed cluster: Raft + reactivity

```
Node C: store.write(:tasks, "t1", {...})
  → Raft: proposal → consensus → committed (term: 43, index: 156)

Node A: Raft log replay fact(term: 43, index: 156)
  → FactLog.append → ReadCache.invalidate → TaskDispatcherAgent(A).trigger_scan

Node B: Raft log replay fact(term: 43, index: 156)
  → FactLog.append → ReadCache.invalidate → TaskDispatcherAgent(B).trigger_scan
```

Reactivity on every node is a direct consequence of Raft replay. No separate
pub/sub infrastructure is needed.

### Push what: invalidation vs fact

| | Push invalidation | Push fact |
|---|---|---|
| Complexity | simple — already in POC | requires schema coercion per consumer |
| Latency | +1 re-fetch | no re-fetch |
| Data volume | minimal (store, key) | full payload |
| Schema safety | agent reads in its own schema | store must know consumer schema version |
| First iteration | **yes** | deferred |

Decision: **push invalidation** — `consumer.call(store, key)`. The agent
re-reads via `store_read` and may hit the cache if another agent already
fetched the new value.

### Scope-aware filtering (deferred)

First iteration: any write to `:tasks` notifies ALL consumers for `:tasks`
regardless of which scope they watch. The agent re-reads and handles gracefully
(most triggers find nothing changed if the relevant scope was not touched).

Future: the store evaluates the scope condition at write time:

```ruby
if scope_condition_touched?(fact, path.scope)
  path.consumers.each { |c| c.call(fact.store, fact.key) }
end
```

Requires: the store can evaluate scope predicates (`where: { status: :pending }`)
against a fact value. Deferred.

### Deferred

| Question | Status |
|--------|--------|
| `tick` macro implementation | Deferred — model decided; sugar ships under pressure |
| `reactive: true` on `store_read` in compiler | Deferred — requires compiler extension |
| Scope-aware consumer filtering | Deferred — first iteration: any write = all notified |
| Push fact (not invalidation) | Deferred — after schema coercion is stable |
| Backpressure on agent mailbox under high write rate | Deferred — benchmark first |
| Consumer de-registration on agent stop | Required — prevent memory leaks; deferred to impl |

---

## Reference

- [Contract Persistence Organic Model](../../../../docs/research/contract-persistence-organic-model.md)
- [Contract Persistence Roadmap](../../../../docs/research/contract-persistence-roadmap.md)
- [Companion Current Status Summary](../../../../packages/igniter-companion/docs/current-status.md)
- [POC Specification](../poc-specification.md)
