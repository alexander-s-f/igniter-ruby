# Track: Ledger Boundary Availability Proof v0

Status date: 2026-05-04
Status: done
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Prove the first concrete `LedgerBoundary` model over the existing Intelligent
Ledger availability example.

The research question:

```text
Can a closed semantic boundary preserve correct replay/output truth after
internal detail has been compacted, without replaying full history?
```

This slice should produce a small in-memory/store-backed proof, not a stable
public API.

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/intelligent-ledger/README.md`
4. `docs/intelligent-ledger/availability-snapshot-proof.md`
5. `docs/intelligent-ledger/ledger-boundaries-compaction-plan.md`
6. this track

Then inspect only the example/spec files named below.

## Current Baseline

Existing proof:

```text
examples/intelligent_ledger/availability_deriver.rb
examples/intelligent_ledger/availability_ledger.rb
spec/igniter/store/intelligent_ledger/availability_snapshot_proof_spec.rb
```

It proves:

- template facts
- override facts
- order event facts
- derived availability snapshot
- derivation receipt linked to source fact IDs

Missing:

- explicit boundary lifecycle
- closed boundary output as replay input
- compaction of internal detail
- cleanup eligibility
- late fact handling after closure

## Naming Rule

Use `LedgerBoundary`.

Do not use:

- `Capsule` — already public in application/hub layer.
- `Container` — already used by embed/UI/general code.
- `Frame` — already storage/wire terminology.

Short local DSL/method names may use `boundary`.

## Scope

Add a focused proof around a technician-day availability boundary.

Suggested class shape:

```text
Igniter::Store::IntelligentLedger::LedgerBoundary
Igniter::Store::IntelligentLedger::AvailabilityBoundaryLedger
```

or a similarly small naming shape if implementation suggests better names.

Do not add the boundary concept to core `IgniterStore` API yet.

### Boundary Type

```text
TechnicianAvailabilityDayBoundary
  subject:
    company_id
    technician_id
    date

  inputs:
    previous_boundary_output_id
    day_off_config/template fact refs
    company window/config refs if available in the proof

  internal facts:
    availability template
    overrides
    order reserved/cancelled events

  output:
    availability snapshot value

  closure:
    result_hash
    source_fact_ids
    output_fact_id
    receipt_fact_id
    detail_status
```

### Lifecycle To Prove

```text
open
  -> accepts facts for technician/date
  -> can derive provisional availability

closed
  -> writes immutable boundary output + closure receipt
  -> boundary replay returns output without full-history scan

compacted
  -> internal detail is marked purged/summarized/archived
  -> boundary replay still returns the same output
  -> full replay reports detail_unavailable
```

## Suggested Store Layout

Keep it app/example-local:

```text
:availability_templates
:availability_overrides
:order_events
:availability_snapshots
:derivation_receipts
:ledger_boundaries
:ledger_boundary_receipts
:ledger_cleanup_receipts
```

This is proof vocabulary. Do not promise stable store names.

## Required Behaviors

### 1. Deterministic Boundary Key

Boundary key should be deterministic from:

```text
policy_name + subject + window + rule_version
```

Example:

```text
technician_day/company=1/technician=tech-1/date=2026-05-04/version=1.0
```

### 2. Close Boundary

Closing a boundary should:

- compute availability snapshot
- write snapshot fact
- write derivation/closure receipt
- write boundary fact/record
- mark status `:closed`
- include `result_hash`
- include source fact refs

### 3. Boundary Replay

Boundary replay should return the closed output without scanning every internal
source fact.

Suggested return:

```ruby
{
  status: :ok,
  fidelity: :boundary,
  output: snapshot_value,
  boundary_id: "...",
  detail_status: :full
}
```

### 4. Full Replay

Full replay should work before compaction.

After compaction/purge:

```ruby
{
  status: :detail_unavailable,
  boundary_id: "...",
  detail_status: :purged,
  boundary_receipt_id: "..."
}
```

### 5. Compact Internals

Compaction in this proof may be logical/in-memory. It does not need to
physically rewrite `IgniterStore`.

But it must:

- mark boundary `detail_status: :purged` or `:summarized`
- keep boundary output
- keep boundary receipt
- write compaction/cleanup receipt
- preserve `result_hash`

### 6. Cleanup Eligibility

Add a small cleanup plan proof:

```ruby
plan = ledger.cleanup_plan(
  store: :order_events,
  before: Time.utc(2026, 5, 5),
  fidelity: :boundary
)
```

Acceptance:

- plan is `:blocked` while required boundary is still open
- plan becomes `:ready` after required boundary closes
- plan includes blocking boundary IDs when blocked
- plan includes boundary receipt/output refs when ready

### 7. Late Facts

A late fact for a closed boundary must not mutate the original boundary.

Default proof behavior:

```text
late fact
  -> correction boundary or late-fact receipt
  -> original boundary result_hash remains unchanged
```

Implement the smallest shape that proves immutability.

## Acceptance

- Full package test suite passes.
- Existing availability snapshot proof remains green.
- New specs live under `spec/igniter/store/intelligent_ledger/`.
- Boundary can be opened/closed for a technician day.
- Boundary close writes output + receipt + deterministic boundary identity.
- Boundary replay returns the same availability output without full-history scan.
- Full replay works before compaction and reports `:detail_unavailable` after
  internal detail is compacted/purged.
- Cleanup plan is blocked by open required boundary and ready after closure.
- Compaction writes a cleanup/compaction receipt.
- Late fact creates correction/late-fact evidence and does not mutate original
  closed boundary.
- No core/public DSL promise is introduced.

## Non-Goals

- No production storage rewrite.
- No physical segment purge.
- No Rust implementation.
- No Ledger Open Protocol operations.
- No HTTP/MCP endpoints.
- No public contract DSL.
- No Spark CRM integration.
- No attempt to solve all boundary types.

## Suggested Files To Inspect

```text
examples/intelligent_ledger/availability_deriver.rb
examples/intelligent_ledger/availability_ledger.rb
spec/igniter/store/intelligent_ledger/availability_snapshot_proof_spec.rb
docs/intelligent-ledger/ledger-boundaries-compaction-plan.md
docs/intelligent-ledger/availability-snapshot-proof.md
```

## Handoff

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/ledger-boundary-availability-proof-v0
Status: done

[D] Decisions:
- LedgerBoundary is a PORO tracking open/closed/compacted state in-memory;
  boundary records and receipts are persisted to the store for durability.
- result_hash is SHA-256 of (output_value.to_s + sorted_source_fact_ids + rule_version).
  It is intentionally not cross-store stable (computed_at and fact UUIDs vary),
  but is immutable within a boundary after close! — which is the required invariant.
- LedgerBoundary.key_for() is a class-level helper for computing deterministic
  boundary keys without instantiating a full boundary object.
- Compaction is logical/in-memory: detail_status -> :purged, output_value retained.
- Late facts write to :late_fact_receipts with disposition "correction_boundary";
  they do not mutate the original boundary.

[S] Shipped:
- examples/intelligent_ledger/ledger_boundary.rb
    LedgerBoundary PORO: open/close/compact lifecycle, result_hash, key_for()
- examples/intelligent_ledger/availability_boundary_ledger.rb
    AvailabilityBoundaryLedger: open_boundary, close_boundary, compact_boundary,
    replay, full_replay, cleanup_plan, write_late_fact
- spec/igniter/store/intelligent_ledger/ledger_boundary_proof_spec.rb
    39 examples covering all 7 acceptance behaviors + delegation regression

[T] Tests:
- 39 new examples, 0 failures
- Full package suite: 837 examples, 0 failures
- Existing availability_snapshot_proof_spec.rb unchanged and green

[R] Risks / next recommendations:
- result_hash depends on output_value.to_s which is sensitive to Hash ordering
  and computed_at; if cross-run content-addressing is required, normalize to
  only semantic fields (available_seconds, available_slots, blocked_intervals).
- Boundary registry is in-memory only; after process restart, boundaries are
  gone. A next step would be hydrating @boundaries from :ledger_boundaries store
  on startup.
- cleanup_plan considers all tracked boundaries regardless of store; filtering
  by which store a boundary's facts live in requires richer metadata.
- No multi-boundary-type support yet; a single technician_day policy is proven.
```
