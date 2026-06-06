# Contract-Native Store: Sync Hub & Retention

Status date: 2026-04-30.
Format: living research document — each iteration appended below.
Scope: PostgreSQL as sync hub, retention policies, hot/cold circuit.
Canonical: this file. Russian companion: `sync-hub-iterations.ru.md`.

---

## Iteration 0 — Two Ideas Explored

*Recorded from design session, 2026-04-30.*

Two ideas were discussed before arriving at the hub model below. Brief record:

### Idea A: PostgreSQL extension

Three levels of ambition:

- **Level A — DDL generator** (Ruby-side): reads `persist` block → generates
  `CREATE TABLE` SQL. Pragmatic, no native extension needed.
- **Level B — Reactive bridge** (C/Rust `pgrx`): adds `NOTIFY` trigger function,
  `igniter_time_travel()` SQL function, causation chain operator.
- **Level C — Contract execution inside PostgreSQL**: contracts compiled to stored
  procedures. Evaluated as over-engineering at this stage.

Decision: Level A+B is real value. Level C deferred indefinitely.

### Idea B: Hot/cold circuit

```
IgniterStore (hot)  →  BackgroundSync  →  PostgreSQL (cold)
in-memory + Raft        async, batch       durable, queryable
```

The write path never blocks on PostgreSQL. BackgroundSync is async.
PostgreSQL serves: durable backup, analytics, cross-cluster bootstrap.

---

## Iteration 1 — Refined Vision: PostgreSQL as Sync Hub

*Recorded from design session, 2026-04-30.*

### User refinement

PostgreSQL first as **backup and seed system** — not deep extension territory.
One simple polymorphic table (`igniter_facts`) that receives facts from all
clusters. Clusters pull what they need. PostgreSQL becomes an all-to-all sync
hub.

### The hub model

```
Cluster A                   PostgreSQL Hub                Cluster B
  IgniterStore                 igniter_facts                 IgniterStore
  (hot, Raft)                  (cold, JSONB)                (hot, Raft)
       │                            │                             │
       │ BackgroundSync             │          BackgroundSync     │
       │ push (async)               │          pull (poll/LISTEN) │
       └──────────────────────────→ │ ←────────────────────────── ┘
                                    │
                              Cluster C, D, … pull the same way
```

Intra-cluster consistency: Raft (strong, fast).
Inter-cluster sync: PostgreSQL hub (async, eventual).

### Hub table — polymorphic, one table for all stores

```sql
CREATE TABLE igniter_facts (
  id             UUID    NOT NULL,
  store          TEXT    NOT NULL,   -- Store[T] or History[T] name
  key            TEXT    NOT NULL,   -- identity within the store
  value          JSONB   NOT NULL,   -- the payload
  value_hash     TEXT    NOT NULL,   -- SHA-256 content address (dedup key)
  causation      TEXT,               -- value_hash of previous fact (chain)
  timestamp      FLOAT8  NOT NULL,   -- wall-clock at write time
  term           INTEGER NOT NULL DEFAULT 0,   -- Raft term
  schema_version INTEGER NOT NULL DEFAULT 1,
  cluster_id     TEXT    NOT NULL,   -- which cluster produced this
  synced_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  retain_until   TIMESTAMPTZ,        -- NULL = keep forever; set by BackgroundSync
  PRIMARY KEY (id, synced_at)        -- composite PK enables time-range partitioning
) PARTITION BY RANGE (synced_at);

-- Partitions by month (created automatically by BackgroundSync or pg_partman)
CREATE TABLE igniter_facts_2026_04
  PARTITION OF igniter_facts
  FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');

-- Core indexes
CREATE INDEX ON igniter_facts (store, key, timestamp DESC);
CREATE UNIQUE INDEX ON igniter_facts (value_hash);   -- content-addressed dedup
CREATE INDEX ON igniter_facts (cluster_id, store, synced_at);
CREATE INDEX ON igniter_facts (retain_until)
  WHERE retain_until IS NOT NULL;                    -- TTL cleanup index
```

**Why polymorphic (one table)?**
- Simple: no schema changes when a new Store[T] is added to a contract
- Easy cross-store queries: `SELECT * FROM igniter_facts WHERE timestamp > X`
- Hub does not know or care about contract semantics — it just stores facts
- `value` is JSONB — any payload, any schema version

**Dedup via `value_hash`:** same content from two clusters arrives once.
`ON CONFLICT (value_hash) DO NOTHING` makes push idempotent.

### Cluster pull: selective subscription

Each cluster declares what it needs from the hub:

```ruby
IgniterStoreBackgroundSync.configure do |c|
  c.hub_url "postgres://hub-host/igniter_hub"

  # Push everything this cluster produces
  c.push :all

  # Pull only stores this cluster cares about
  c.pull :articles                                     # all articles
  c.pull :tasks, scope: :pending                       # only pending tasks
  c.pull :sensor_readings, from_cluster: "eu-west-1"  # only from specific cluster

  # Ignore high-volume stores from other clusters
  c.ignore :agent_signals, from_clusters: :others
end
```

### Reactive pull via LISTEN/NOTIFY

```sql
CREATE FUNCTION igniter_hub_notify() RETURNS trigger AS $$
BEGIN
  PERFORM pg_notify(
    'igniter_hub',
    json_build_object(
      'store',      NEW.store,
      'key',        NEW.key,
      'cluster_id', NEW.cluster_id
    )::text
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER igniter_facts_notify
  AFTER INSERT ON igniter_facts
  FOR EACH ROW EXECUTE FUNCTION igniter_hub_notify();
```

Ruby side — cluster B subscribes:

```ruby
hub.listen("igniter_hub") do |notification|
  meta = JSON.parse(notification.extra, symbolize_names: true)
  next unless local_store.subscribed?(meta[:store].to_sym)
  next if meta[:cluster_id] == local_cluster_id   # skip own facts

  fact = hub.fetch_fact(meta[:store], meta[:key])
  local_store.log.replay(fact) if fact
end
```

---

## Iteration 2 — Retention Policies

*Recorded from design session, 2026-04-30.*

### The problem: not all facts are equal

Some facts must be kept forever:
- Business records (`Store[:articles]`, `Store[:contracts]`)
- Audit events (`History[:materializer_approvals]`)
- Schema change history (`History[:contract_spec_changes]`)

Others are high-volume and transient:
- Sensor readings (`History[:sensor_readings]`)
- Agent signals (`History[:agent_signals]`)
- Health check pings (`History[:node_pings]`)

Without retention policies the hub grows unboundedly. A cleanup mechanism is
required.

### Retention declared in the contract

Retention is co-located with the storage declaration — two levels:

```ruby
class SensorContract < Igniter::Contract
  history :sensor_readings, partition_key: :sensor_id do
    # hot: how long to keep in IgniterStore (in-memory / local WAL)
    # cold: how long to keep in PostgreSQL hub
    retention hot: 1.hour, cold: 7.days

    field :sensor_id,   type: :string
    field :value,       type: :float
    field :recorded_at, type: :float
  end

  history :agent_signals, partition_key: :agent_id do
    retention hot: 15.minutes, cold: 24.hours
    field :agent_id, type: :string
    field :signal,   type: :symbol
  end

  persist :calibration, key: :sensor_id do
    retention hot: :forever, cold: :forever   # default; explicit for clarity
    field :sensor_id,   type: :string
    field :calibration, type: :float
  end
end
```

`BackgroundSync` reads retention metadata from the contract's manifest and sets
`retain_until = NOW() + cold_ttl` when pushing facts to the hub.

### Three cleanup strategies

**Strategy 1 — Partition drop** (zero write overhead, for high-volume transient)

```sql
-- Drop the entire month's partition when all facts in it are expired
DROP TABLE IF EXISTS igniter_facts_2026_01;
```

Best for: `History[:sensor_readings]`, `History[:agent_signals]`.
Works when the entire partition is past retention. Handled by a scheduler
(pg_cron or BackgroundSync's built-in sweeper).

**Strategy 2 — Row-level TTL** (selective, for mixed stores)

```sql
-- Nightly sweeper job:
DELETE FROM igniter_facts
WHERE retain_until IS NOT NULL
  AND retain_until < NOW();
```

Best for: stores where some facts are important and some are transient.
`retain_until` is set per-fact by BackgroundSync based on retention policy.

**Strategy 3 — Compaction** (keep current state, drop history)

For `Store[T]` (mutable records) where only the latest version matters:
keep the most recent fact per key, delete older versions beyond a threshold.

```sql
-- Keep only the latest fact per (store, key); delete others older than N days
DELETE FROM igniter_facts f
WHERE f.store = 'sensor_calibration'
  AND f.timestamp < (NOW() - INTERVAL '30 days')::FLOAT8
  AND f.id NOT IN (
    SELECT DISTINCT ON (store, key) id
    FROM igniter_facts
    WHERE store = 'sensor_calibration'
    ORDER BY store, key, timestamp DESC
  );
```

Best for: configuration stores, last-known-value stores.

### Strategy selection per store

| Store type | Default strategy | Rationale |
|---|---|---|
| `persist` (mutable) | compaction | only current state usually matters |
| `history` with `retention: :forever` | none | keep everything |
| `history` with short TTL | partition drop or row TTL | volume determines which |
| audit / approval histories | none | legal/compliance requirement |

### Hot circuit cleanup: IgniterStore WAL

When `retention hot: 1.hour` is declared:

- FactLog holds a sliding window: facts older than `hot_ttl` are eligible for
  eviction from the in-memory index and the local WAL file.
- Facts already synced to the hub may be evicted first.
- Facts not yet synced are retained until `BackgroundSync` confirms the push.

```
hot_retention sweep (periodic):
  for each fact in FactLog:
    if fact.timestamp < (now - hot_ttl)
      AND fact is confirmed synced to hub:
        evict from @by_key index
        mark as evicted in WAL (do not delete WAL line — append-only)
```

### Causation chain safety

A fact should not be deleted from the hub if it is a `causation` reference for
a retained fact. Otherwise, causation chains become broken.

First iteration: **ignore causation safety during cleanup** — document it as
a known limitation. Causation chains may have gaps after cleanup.

Future: a GC-style pass that marks all retained facts, follows causation chains
backward, and marks reachable ancestors as also retained before deletion.

---

## Iteration 3 — Open Questions

*Recorded from design session, 2026-04-30.*

### Q1 — Conflict resolution between clusters

Two clusters write different values for the same `(store, key)` in the same
time window. Both facts arrive at the hub. Which one wins when Cluster B pulls?

Options:
- **Last-writer-wins by timestamp** — simple; unreliable under clock skew.
- **Last-writer-wins by Raft term** — reliable within a cluster; cross-cluster
  term spaces are independent (term=42 on A ≠ term=42 on B).
- **Explicit merge contract** — a declared contract that resolves conflicts
  per-store semantically. Most correct; most complex.
- **Append-only conflict** — for `History[T]`, both facts are kept (both are
  events). For `Store[T]` (mutable), conflict is flagged and requires explicit
  resolution.

First iteration: last-writer-wins by timestamp for `Store[T]`;
both facts kept for `History[T]`.

### Q2 — Hub capacity planning

High-volume stores with short retention (sensors, signals) still create
write pressure on the hub during the retention window.

Mitigation options:
- Separate hub tables per retention tier (hot-tier: 24h, warm-tier: 30d,
  cold-tier: forever) — avoids cross-tier partition pressure.
- Sampling: push only 1-in-N facts for sensor stores to the hub.
- Aggregation at BackgroundSync: instead of individual sensor facts, push
  hourly aggregate summaries.

First iteration: no mitigation. Add when write pressure is observed.

### Q3 — Bootstrap ordering

When a new cluster restores from the hub, it replays facts in `timestamp` order.
If `timestamp` is unreliable (clock skew), replay order may be wrong.

Mitigation: replay by `(term, synced_at)` — `synced_at` is hub-assigned and
monotonic per partition. This gives hub-authoritative ordering for bootstrap.

### Q4 — PostgreSQL extension (deferred)

DDL generator (Level A) and reactive NOTIFY trigger (Level B) are still on
the table for a future `igniter-hub` package. Not in scope until the hub
model is stable.

---

## Next Steps

Priority order:

1. Prove the polymorphic hub table with a minimal BackgroundSync in Ruby under
   `packages/igniter-ledger`; keep the old `examples/igniter_store_poc.rb` as
   reference-only.
2. Decide on conflict resolution for `Store[T]` (Q1)
3. Implement retention policy declarations in the `persist`/`history` DSL
4. Implement partition drop sweeper for high-volume transient histories

---

## Reference

- [Contract-Native Store Research](./store-iterations.md)
- [Contract-Native Store POC](../poc-specification.md)
- [POC source](../../../../examples/igniter_store_poc.rb)
- [POC package](../../README.md)
