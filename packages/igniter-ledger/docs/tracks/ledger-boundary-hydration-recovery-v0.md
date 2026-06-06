# Track: Ledger Boundary Hydration Recovery v0

Status date: 2026-05-04
Status: done
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Make the LedgerBoundary availability proof survive a process restart.

The current proof persists boundary/settlement/compaction receipts, but the
active boundary registry is in-memory:

```ruby
@boundaries = {}
```

After a new `AvailabilityBoundaryLedger.new(store: same_store)`, replay,
cleanup planning, compaction guards, and late-fact handling lose the boundary
state unless the registry is hydrated from persisted facts.

Research question:

```text
Can boundary truth be restored from persisted receipts strongly enough that
boundary replay and cleanup semantics still work after restart?
```

Keep this as a proof under `examples/intelligent_ledger`; do not promote it to
core/public API.

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/intelligent-ledger/README.md`
4. `docs/intelligent-ledger/ledger-boundaries-compaction-plan.md`
5. `docs/tracks/ledger-boundary-availability-proof-v0.md`
6. `docs/tracks/ledger-boundary-settlement-proof-v0.md`
7. this track

Then inspect only the example/spec files named below.

## Current Baseline

`ledger-boundary-settlement-proof-v0` landed:

```text
LedgerBoundary
  status: open | closed | compacted
  settlement_status: unsettled | settled

AvailabilityBoundaryLedger
  open_boundary
  close_boundary
  settle_boundary
  compact_boundary
  replay
  full_replay
  cleanup_plan
  write_late_fact
```

Persisted stores:

```text
:ledger_boundaries
:ledger_boundary_receipts
:ledger_boundary_summaries
:ledger_boundary_metrics
:ledger_settlement_receipts
:ledger_cleanup_receipts
:late_fact_receipts
```

Known gap:

```text
new AvailabilityBoundaryLedger(store: same_store)
  -> @boundaries empty
  -> replay(boundary_key) returns :not_found
```

## Scope

Add a hydration/recovery path.

Suggested API:

```ruby
ledger = AvailabilityBoundaryLedger.new(store: store)
ledger.hydrate_boundaries
```

or constructor option:

```ruby
ledger = AvailabilityBoundaryLedger.new(store: store, hydrate: true)
```

Choose the simpler implementation. Prefer explicit `hydrate_boundaries` unless
constructor hydration is cleaner.

## Hydration Semantics

Hydration should rebuild enough in-memory `LedgerBoundary` state from persisted
facts to support:

- `find_boundary(boundary_key)`
- `replay(boundary_key)`
- `full_replay(...)`
- `cleanup_plan(...)`
- `compact_boundary(boundary_key)` where applicable
- `write_late_fact(...)`

Hydration should consider the latest facts for a boundary key in these stores:

```text
:ledger_boundaries
:ledger_boundary_receipts
:ledger_settlement_receipts
:ledger_cleanup_receipts
```

It may read summary/metrics stores only if needed for tests.

## Required Restored Fields

Hydrated boundary must restore at least:

```text
boundary_key
subject
status
detail_status
source_fact_ids
output_fact_id
output_value
receipt_fact_id
result_hash
settlement_status
settlement_receipt_id
compaction_receipt_id
closed_at / compacted_at if available
```

`output_value` can be recovered by reading `:availability_snapshots` using
`output_fact_id`. If direct read by fact id is awkward, use the latest snapshot
referenced by the boundary receipt in this proof and document the choice.

## Hydration Result Shape

Return a compact report:

```ruby
{
  status: :ok,
  hydrated_count: 3,
  skipped_count: 0,
  warnings: []
}
```

If a persisted boundary is incomplete, skip it with a warning rather than
raising unless the corruption is impossible to ignore.

## Acceptance

- Full package test suite passes.
- Existing boundary availability and settlement specs remain green.
- New specs live under `spec/igniter/store/intelligent_ledger/`.
- A closed boundary can be hydrated in a fresh `AvailabilityBoundaryLedger`.
- `replay(boundary_key)` works after hydration and returns the original output.
- A settled boundary hydrates with `settlement_status: :settled`.
- A compacted boundary hydrates with `status: :compacted` and
  `detail_status: :purged`.
- `full_replay` after hydration reports `:detail_unavailable` for compacted
  boundaries.
- `cleanup_plan` after hydration is blocked for open/unsettled persisted
  boundaries and ready for settled boundaries.
- `compact_boundary` works after hydration for settled-but-uncompacted
  boundaries.
- `write_late_fact` works after hydration and records restored status fields.
- Hydration is idempotent: running it twice does not duplicate in-memory
  boundaries or write new facts.
- Hydration report includes counts.

## Edge Cases To Cover

- No persisted boundaries: returns hydrated_count 0.
- Boundary record exists but closure receipt is missing: skipped with warning.
- Settlement receipt exists: restored as settled.
- Cleanup receipt exists: restored as compacted/purged.
- Hydrating after multiple boundary facts for same key uses latest persisted
  state.

## Non-Goals

- No production storage rewrite.
- No physical segment purge.
- No Rust implementation.
- No Ledger Open Protocol operations.
- No HTTP/MCP endpoints.
- No public contract DSL.
- No Spark CRM integration.
- No generic boundary registry for all boundary types.
- No cross-process locking.

## Suggested Files To Inspect

```text
examples/intelligent_ledger/ledger_boundary.rb
examples/intelligent_ledger/availability_boundary_ledger.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_proof_spec.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_settlement_proof_spec.rb
docs/tracks/ledger-boundary-availability-proof-v0.md
docs/tracks/ledger-boundary-settlement-proof-v0.md
```

## Handoff

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/ledger-boundary-hydration-recovery-v0
Status: done

[D] Decisions:
- hydrate_boundaries implemented as an explicit method (not constructor option) — simpler
  to call selectively and avoids mutating constructor semantics.
- Status is authoritative from receipt evidence: presence of a cleanup receipt in
  :ledger_cleanup_receipts → :compacted/:purged, regardless of what the boundary record
  says. The boundary record is written at close time and never updated on compaction.
- output_value recovered via linear scan of :availability_snapshots by output_fact_id.
  Documented choice: direct read by fact_id is awkward with the current store API; scan
  is acceptable for this proof scope.
- Hydration is idempotent via early-exit: `next if @boundaries.key?(bk)`. Second call
  returns hydrated_count: 0 without touching the store.
- Boundaries with a persisted record but no closure receipt are skipped with a warning
  (not raised) — treats them as incomplete writes, not corruption.
- LedgerBoundary.from_persisted uses allocate + private restore_from_record! to bypass
  initialize — avoids re-running boundary_key derivation logic on already-persisted keys.

[S] Shipped:
- examples/intelligent_ledger/ledger_boundary.rb (updated)
    Added: LedgerBoundary.from_persisted class method.
    Added: private restore_from_record! — rebuilds all state fields from persisted data.
    Added: private parse_time_safe helper.
- examples/intelligent_ledger/availability_boundary_ledger.rb (updated)
    Added: hydrate_boundaries — scans :ledger_boundaries, cross-references receipt stores,
    builds LedgerBoundary.from_persisted, registers in @boundaries.
    Added: private find_snapshot_value(fact_id) — linear scan of :availability_snapshots.
    Added: private safe_parse_time(val) helper.
- spec/igniter/store/intelligent_ledger/ledger_boundary_hydration_recovery_proof_spec.rb (new)
    35 examples across 10 scenarios covering all hydration recovery acceptance criteria.

[T] Tests:
- 35 new hydration recovery proof examples, 0 failures
- 912/912 full package suite examples, 0 failures
- All existing availability and settlement proof specs remain green

[R] Risks / next recommendations:
- find_snapshot_value is O(n) over all :availability_snapshots; fine for proof scope but
  would need a keyed lookup if the snapshot count grows large.
- hydrate_boundaries reads the full :ledger_boundaries history to group by key; a
  production path would want key-range or time-bounded queries.
- Settlement idempotency gap from Track 2 remains: re-running settle_boundary on a fresh
  ledger instance writes duplicate settlement facts. Hydration is the correct guard —
  hydrate first, then settle_boundary raises on already-settled boundaries.
- No cross-process locking: if two processes hydrate and then both try to close/settle the
  same boundary key, they will both write to the store. Out of scope for this proof.
```
