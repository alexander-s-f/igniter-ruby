# Track: Ledger Boundary Settlement Proof v0

Status date: 2026-05-04
Status: done
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Extend the `LedgerBoundary` availability proof with a pre-compaction
settlement stage.

The research question:

```text
Before a boundary loses internal detail, can it materialize useful long-lived
memory as summaries, reports, metrics, and settlement receipts?
```

This is the next slice after `ledger-boundary-availability-proof-v0`. Keep it a
proof in `examples/intelligent_ledger`; do not promote it to core/public API.

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/intelligent-ledger/README.md`
4. `docs/intelligent-ledger/ledger-boundaries-compaction-plan.md`
5. `docs/tracks/ledger-boundary-availability-proof-v0.md`
6. this track

Then inspect only the example/spec files named below.

## Current Baseline

`ledger-boundary-availability-proof-v0` landed:

```text
LedgerBoundary
  open -> closed -> compacted

AvailabilityBoundaryLedger
  open_boundary
  close_boundary
  compact_boundary
  replay
  full_replay
  cleanup_plan
  write_late_fact
```

Current limitation:

```text
closed -> compacted
```

is too abrupt. Before compaction, the boundary should settle useful memory:

```text
closed
  -> settling
     -> settled
        -> compacted
```

## Scope

Add a settlement stage to the existing proof.

Suggested API shape:

```ruby
ledger.settle_boundary(boundary_key)
```

or:

```ruby
ledger.settle_boundary(boundary_key, transforms: ...)
```

Use the smallest explicit shape that proves the model.

## Settlement Outputs To Prove

For the technician-day availability boundary, materialize at least three
pre-compaction outputs:

### 1. Availability Summary

Persist a summary fact, for example in:

```text
:ledger_boundary_summaries
```

Minimum fields:

```text
boundary_key
summary_type: "availability"
available_seconds
available_slot_count
blocked_interval_count
source_fact_count
result_hash
```

### 2. Metrics

Persist one or more metric facts, for example in:

```text
:ledger_boundary_metrics
```

Minimum metrics:

```text
capacity_percent
available_hours
blocked_hours
```

### 3. Settlement Receipt

Persist a settlement receipt, for example in:

```text
:ledger_settlement_receipts
```

Minimum fields:

```text
boundary_key
settlement_status: "settled"
transform_names
output_fact_ids
result_hash
settled_at
```

The exact store names may differ, but keep them proof-local and documented in
comments.

## Boundary State

Extend `LedgerBoundary` state enough to represent:

```text
open
closed
settled
compacted
```

or keep `status` closed/compacted and add `settlement_status`, if that is
cleaner.

Acceptance requires:

- a closed but unsettled boundary cannot compact
- after settlement, compaction is allowed
- replay still works after settlement and after compaction
- settlement metadata remains visible after compaction

## Transform Receipts

Each transform should produce inspectable evidence.

Suggested shape:

```ruby
{
  transform_name: "availability_summary",
  transform_version: "1.0",
  input_boundary_key: "...",
  input_result_hash: "...",
  output_fact_id: "...",
  output_hash: "...",
  status: "ok"
}
```

This can be embedded in the settlement receipt or written as separate facts.
Choose the smaller implementation.

## Cleanup Eligibility

Update `cleanup_plan` to consider settlement:

```text
open boundary
  -> blocked

closed but unsettled boundary
  -> blocked, reason: :settlement_required

settled boundary
  -> ready
```

The plan should expose enough reason data:

```ruby
{
  status: :blocked,
  blocking_boundaries: [...],
  blocking_reasons: {
    boundary_key => :settlement_required
  }
}
```

If implementing a separate `blocking_reasons` hash is too much, include a small
reason field in the blocking entries.

## Compaction Rule

`compact_boundary` must enforce:

```text
boundary must be closed
AND settlement_status must be settled
```

Compaction receipt should reference the settlement receipt.

## Late Facts

If a late fact arrives after settlement or compaction:

- original boundary result_hash remains unchanged
- settlement outputs remain unchanged
- late-fact receipt records whether boundary was `settled` or `compacted`
- disposition remains correction-oriented, not mutation

## Acceptance

- Full package test suite passes.
- Existing `ledger_boundary_proof_spec.rb` remains green or is updated without
  weakening its assertions.
- New specs live under `spec/igniter/store/intelligent_ledger/`.
- `settle_boundary` persists summary, metrics, and settlement receipt.
- Closed-but-unsettled boundary cannot compact.
- Settled boundary can compact.
- Cleanup plan is blocked for open boundaries.
- Cleanup plan is blocked for closed-but-unsettled boundaries with a settlement
  reason.
- Cleanup plan is ready after settlement.
- Boundary replay still returns the same output after settlement and compaction.
- Full replay reports `:detail_unavailable` after compaction.
- Late facts after settlement/compaction do not mutate original output,
  result_hash, or settlement outputs.
- No core/public DSL promise is introduced.

## Non-Goals

- No production storage rewrite.
- No physical segment purge.
- No Rust implementation.
- No Ledger Open Protocol operations.
- No HTTP/MCP endpoints.
- No public contract DSL.
- No Spark CRM integration.
- No generic transform engine.
- No Kalman/geo implementation in this slice.

## Suggested Files To Inspect

```text
examples/intelligent_ledger/ledger_boundary.rb
examples/intelligent_ledger/availability_boundary_ledger.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_proof_spec.rb
docs/intelligent-ledger/ledger-boundaries-compaction-plan.md
docs/tracks/ledger-boundary-availability-proof-v0.md
```

## Handoff

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/ledger-boundary-settlement-proof-v0
Status: done

[D] Decisions:
- settlement_status kept as a separate attribute (:unsettled/:settled) on LedgerBoundary
  rather than promoting :settled into the main status enum. This avoids breaking the
  closed?/compacted? predicates and keeps the lifecycle clean.
- compact! enforces settled? first; raises ArgumentError if called on unsettled boundary.
- cleanup_plan now separates open_blocking vs. unsettled_blocking and emits
  blocking_reasons: { boundary_key => :open | :settlement_required }.
- Two settlement transforms: availability_summary and availability_metrics.
  capacity_percent uses a 24h day denominator (not shift length) — documented in comments.
- Per-transform receipts embedded in the settlement receipt (not separate store).
- write_late_fact records boundary_status_at_arrival and settlement_status_at_arrival.
- Store normalises string keys to symbols on read-back — spec uses symbol keys for
  transform array elements (discovered via one test failure, fixed immediately).

[S] Shipped:
- examples/intelligent_ledger/ledger_boundary.rb (updated)
    Added: settlement_status, settlement_receipt_id, settle!, settled? predicate.
    Updated compact! to require settlement first.
- examples/intelligent_ledger/availability_boundary_ledger.rb (updated)
    Added: settle_boundary (summary + metrics + settlement receipt + transform receipts).
    Updated compact_boundary: settlement guard + settlement_receipt_id in cleanup receipt.
    Updated cleanup_plan: unsettled_blocking + blocking_reasons.
    Updated write_late_fact: boundary_status_at_arrival + settlement_status_at_arrival.
    Updated store layout comment.
- spec/igniter/store/intelligent_ledger/ledger_boundary_proof_spec.rb (updated)
    Scenarios 4/5/6/7: added settle_boundary before compact_boundary calls.
    Scenario 6: three "ready after closure" tests updated to "ready after settlement".
- spec/igniter/store/intelligent_ledger/ledger_boundary_settlement_proof_spec.rb (new)
    40 examples across 10 scenarios covering all settlement acceptance criteria.

[T] Tests:
- 40 new settlement proof examples, 0 failures
- 87/87 intelligent_ledger specs
- Full package suite: 877 examples, 0 failures
- Existing availability_snapshot_proof_spec.rb unchanged and green

[R] Risks / next recommendations:
- capacity_percent uses 24h/day denominator — if shift-relative capacity is needed,
  the settlement transform needs to know the expected shift length (not in boundary yet).
- Settlement is idempotent at the boundary level (raises if already settled), but
  store writes are not deduplication-safe — re-running settle_boundary on a new store
  instance would write duplicate facts. Idempotency requires hydration from store.
- Transform registry: currently two hardcoded transforms; a next step would be a small
  transform registry so domain-specific settlement passes can be added without modifying
  AvailabilityBoundaryLedger directly.
- No settlement for partial-day schedules yet; blocked_hours calculation assumes simple
  interval subtraction which is correct for this proof but may diverge with DST.
```
