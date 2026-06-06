# Availability Snapshot Proof

**Package:** igniter-ledger
**Track:** intelligent-ledger/availability-snapshot-proof
**Status:** proven
**Date:** 2026-05-03

## What this proves

The first practical Intelligent Ledger use case: materialising a derived
`AvailabilitySnapshotFact` for a Spark CRM technician from base facts.

The derivation chain:

```
base facts
  :availability_templates   (weekly schedule)
  :availability_overrides   (explicit time blocks)
  :order_events             (reserved / cancelled)
       ↓  AvailabilityDeriver (pure interval arithmetic)
  :availability_snapshots   (materialized snapshot fact)
  :derivation_receipts      (audit trail)
```

## Stores

| Store | Key | Description |
|---|---|---|
| `:availability_templates` | `technician_id` | Weekly schedule by wday |
| `:availability_overrides` | `technician_id/override_id` | Explicit block intervals |
| `:order_events` | `order_id` | Latest event: `reserved` or `cancelled` |
| `:availability_snapshots` | `technician_id/horizon_start/Nd` | Derived snapshot |
| `:derivation_receipts` | `snapshot_fact_id` | Audit receipt |

## Components

### AvailabilityDeriver

Pure computation — no store access.  Takes `base_facts`, `horizon_start`,
`horizon_days`, and `source_fact_ids`.  Returns a snapshot value hash.

- Template expansion: iterates the horizon window, looks up `weekly_schedule[wday]`
- Interval subtraction: handles no-overlap, trim, split, full-cover cases
- `available_seconds` is the sum of remaining intervals in seconds (integer)

### AvailabilityLedger

Store-backed orchestrator.  Reads base facts, drives the deriver, persists
the snapshot and receipt.

```ruby
ledger = Igniter::Store::IntelligentLedger::AvailabilityLedger.new(store: store)

ledger.write_template(technician_id: "t1", weekly_schedule: { "1" => [["09:00","17:00"]], ... })
ledger.write_override(technician_id: "t1", override_id: "ov-1", start_time: ts, end_time: ts2)
ledger.write_order_event(order_id: "o1", technician_id: "t1", start_time: ts, end_time: ts2, type: "reserved")

result = ledger.compute_snapshot(technician_id: "t1", horizon_start: Date.today, horizon_days: 5)
result[:snapshot_fact]  # → Fact with :available_slots, :available_seconds, :derived_from_fact_ids
result[:receipt_fact]   # → Fact with :snapshot_fact_id, :derivation_version
```

## Seven proven scenarios

1. **Template-only** — 5 days × 8h = 40h (144 000s)
2. **Override blocks** — partial interval subtracted from available window
3. **Order reservation** — reserved interval subtracted
4. **Cancellation restores** — latest event `cancelled` → slot not blocked
5. **Recompute** — second derive after new fact produces distinct Fact with updated value
6. **Source traceability** — `derived_from_fact_ids` contains template, override, and order fact IDs
7. **Receipt integrity** — receipt `snapshot_fact_id` matches snapshot Fact `.id`;
   `derivation_version` == `"1.0"`

## Key implementation notes

- **Symbol keys**: the native extension normalises all Fact value keys to symbols.
  Reads use `:weekly_schedule`, `:start`, `:end`, `:type`, `:available_seconds`, etc.
- **Cancellation semantics**: the latest order event per `order_id` wins.  A `cancelled`
  event prevents the interval from appearing in `blocked_intervals`.
- **Idempotent recompute**: calling `compute_snapshot` twice appends a new Fact at the
  same store key.  Readers use `history(...).last` to get the freshest snapshot.

## What is NOT included

- Incremental / reactive re-derivation on base fact write
- Cross-technician queries
- Horizon caching (every call re-derives from scratch)
- Time-zone awareness (all timestamps are UTC floats)
