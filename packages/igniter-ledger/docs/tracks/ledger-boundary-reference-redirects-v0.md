# Track: Ledger Boundary Reference Redirects v0

Status date: 2026-05-04
Status: done
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Prove that LedgerBoundary compaction can stay referentially honest.

After `ledger-boundary-hydration-recovery-v0`, boundary state survives restart,
but references to raw internal facts still have an unresolved future:

```text
NotificationFact -> references order_event fact-123

later:
  fact-123 is compacted/purged inside TechnicianDayBoundary

question:
  does the reference break, silently downgrade, or redirect to boundary proof?
```

This slice should add a proof-level redirect model under
`examples/intelligent_ledger`. Do not promote it to Ledger Open Protocol, HTTP,
MCP, or public API.

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/intelligent-ledger/README.md`
4. `docs/intelligent-ledger/ledger-boundaries-compaction-plan.md`
5. `docs/tracks/ledger-boundary-availability-proof-v0.md`
6. `docs/tracks/ledger-boundary-settlement-proof-v0.md`
7. `docs/tracks/ledger-boundary-hydration-recovery-v0.md`
8. this track

Then inspect only the example/spec files named below unless blocked.

## Current Baseline

Landed proof stack:

```text
AvailabilityBoundaryLedger
  open_boundary
  close_boundary
  settle_boundary
  compact_boundary
  hydrate_boundaries
  replay / full_replay
  cleanup_plan
  write_late_fact
```

Lifecycle:

```text
open -> closed -> settled -> compacted
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
raw fact refs do not have a redirect/proof path after compaction
```

## Scope

Add a proof-level reference redirect path:

```ruby
ledger.resolve_ref(fact_id, fidelity: :raw)
ledger.resolve_ref(fact_id, fidelity: :boundary)
ledger.resolve_ref(fact_id, fidelity: :summary)
```

and persist redirect facts when a settled boundary is compacted.

Suggested new store:

```text
:ledger_fact_redirects
```

Suggested redirect value:

```ruby
{
  "original_fact_id"          => "...",
  "original_store"            => "order_events",
  "boundary_key"              => "...",
  "boundary_policy"           => "technician_day",
  "boundary_output_fact_id"   => "...",
  "boundary_receipt_id"       => "...",
  "settlement_receipt_id"     => "...",
  "compaction_receipt_id"     => "...",
  "detail_status"             => "purged",
  "reference_role"            => "included_in_boundary",
  "compacted_at"              => "..."
}
```

Keep this simple and explicit. It can be a method on
`AvailabilityBoundaryLedger`; a separate `FactRedirect` value object is welcome
only if it keeps the proof clearer.

## Reference Resolution Semantics

Resolution should be explicit about required fidelity.

### Raw fidelity

```ruby
resolve_ref(fact_id, fidelity: :raw)
```

Outcomes:

```ruby
{ status: :ok, kind: :raw_fact, fact: fact }

{ status: :detail_unavailable,
  original_fact_id: fact_id,
  boundary_key: "...",
  required_fidelity: :raw,
  available_fidelity: :boundary,
  evidence: { ... } }

{ status: :not_found, original_fact_id: fact_id }
```

Raw mode must not silently return boundary evidence as if it were the raw fact.

### Boundary fidelity

```ruby
resolve_ref(fact_id, fidelity: :boundary)
```

Outcomes:

```ruby
{ status: :ok, kind: :raw_fact, fact: fact }

{ status: :redirected,
  kind: :boundary_ref,
  original_fact_id: fact_id,
  boundary_key: "...",
  detail_status: :purged,
  evidence: {
    boundary_output_fact_id: "...",
    boundary_receipt_id: "...",
    settlement_receipt_id: "...",
    compaction_receipt_id: "..."
  } }

{ status: :not_found, original_fact_id: fact_id }
```

Boundary mode may follow redirects.

### Summary fidelity

```ruby
resolve_ref(fact_id, fidelity: :summary)
```

For this proof, summary mode can return the same redirect shape as boundary mode
plus settlement evidence. It does not need to read summary/metrics facts unless
that is easy and useful.

## Compaction Rule

When `compact_boundary(boundary_key)` runs, it should write redirect entries for
the boundary's `source_fact_ids`.

Important:

- This proof does not physically purge raw facts yet.
- The redirect still models the post-purge reference target.
- If raw facts still exist, `fidelity: :raw` may return raw facts.
- Add an option or proof helper to simulate raw detail unavailable after
  compaction if needed for clear tests.

Suggested simple path:

```ruby
compact_boundary(boundary_key, simulate_purge: false)
```

or:

```ruby
resolve_ref(fact_id, fidelity: :raw, assume_compacted: true)
```

Choose the least invasive implementation. The important behavior is that the
redirect proof exists and resolution does not silently downgrade raw fidelity.

## Hydration / Restart

Redirect resolution must work after restart:

```ruby
ledger1.compact_boundary(boundary_key)

ledger2 = AvailabilityBoundaryLedger.new(store: same_store)
ledger2.hydrate_boundaries
ledger2.resolve_ref(source_fact_id, fidelity: :boundary)
  -> :redirected
```

If redirect resolution does not need hydrated boundaries, that is acceptable,
but tests should still include a fresh ledger instance to prove persisted
redirect facts are enough.

## Acceptance

- Full package test suite passes.
- Existing boundary availability, settlement, and hydration specs remain green.
- New specs live under `spec/igniter/store/intelligent_ledger/`.
- Compaction writes one redirect per `source_fact_id`.
- Redirect entry preserves:
  - original fact id
  - original store if known
  - boundary key
  - boundary output fact id
  - boundary receipt id
  - settlement receipt id
  - compaction receipt id
  - detail status
  - reference role
- `resolve_ref(..., fidelity: :boundary)` returns `:redirected` for compacted
  source facts.
- `resolve_ref(..., fidelity: :raw)` does not silently downgrade. It returns raw
  if raw exists and returns `:detail_unavailable` when the proof simulates or
  marks raw detail as unavailable.
- `resolve_ref(..., fidelity: :summary)` returns at least boundary/settlement
  evidence.
- Resolution works after `hydrate_boundaries` on a fresh ledger instance.
- Unknown fact id returns `:not_found`.
- Duplicate compaction or repeated redirect generation is idempotent, or the
  test documents that existing `compact_boundary` prevents repeated compaction.
- Track handoff is appended at the end of this file.

## Edge Cases To Cover

- Boundary has no `source_fact_ids`: compaction writes zero redirects and still
  succeeds.
- Redirect exists but boundary is not hydrated: resolution still returns
  persisted evidence.
- Raw fact exists and redirect exists: `fidelity: :raw` prefers raw unless raw
  purge/unavailable is explicitly simulated.
- Multiple redirects for same fact id: use latest by transaction time.
- Unsupported fidelity raises `ArgumentError`.

## Non-Goals

- No physical raw fact deletion.
- No segment purge.
- No cross-store global resolver.
- No relation index implementation.
- No Ledger Open Protocol operation.
- No HTTP/MCP endpoint.
- No Rust implementation.
- No public DSL.
- No Spark CRM integration.

## Suggested Files To Inspect

```text
examples/intelligent_ledger/ledger_boundary.rb
examples/intelligent_ledger/availability_boundary_ledger.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_proof_spec.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_settlement_proof_spec.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_hydration_recovery_proof_spec.rb
docs/intelligent-ledger/ledger-boundaries-compaction-plan.md
```

## Handoff

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/ledger-boundary-reference-redirects-v0
Status: done

[D] Decisions:
- compact_boundary now writes one :ledger_fact_redirects entry per source_fact_id,
  keyed by the original fact_id. The redirect is written before compact! is called on
  the boundary so compaction_receipt_id is already resolved.
- original_store field is "unknown" — we don't track per-fact store provenance at
  compaction time without an additional scan; documented in comment.
- resolve_ref reads :ledger_fact_redirects directly from the persisted store, so it
  works on fresh ledger instances without hydrate_boundaries. Restart proof confirmed.
- :raw fidelity with assume_compacted: false: attempts find_raw_fact (scans
  RAW_PROOF_STORES = [:availability_templates, :availability_overrides, :order_events]).
  Returns :ok with the fact object when raw is physically accessible. This proves raw
  fidelity does NOT silently downgrade when facts are still present.
- :raw fidelity with assume_compacted: true: skips raw scan, returns :detail_unavailable
  if redirect exists. Simulates physical purge without actually deleting facts.
- :summary fidelity returns kind: :summary_ref; evidence shape identical to :boundary
  (settlement_receipt_id already present in the redirect record — no separate store scan).
- Multiple redirects for same key: latest by transaction_time wins (max_by).
- Zero source_fact_ids: compact_boundary skips redirect loop silently; compaction succeeds.
- RAW_PROOF_STORES constant placed at class level (above the class body) as a module
  constant under AvailabilityBoundaryLedger.

[S] Shipped:
- examples/intelligent_ledger/availability_boundary_ledger.rb (updated)
    compact_boundary: added redirect write loop over source_fact_ids → :ledger_fact_redirects.
    Added public resolve_ref(fact_id, fidelity:, assume_compacted: false).
    Added private: latest_redirect, find_raw_fact, redirect_evidence,
      raw_detail_unavailable, boundary_redirect_response, summary_redirect_response.
    Added RAW_PROOF_STORES constant.
    Updated store layout comment.
- spec/igniter/store/intelligent_ledger/ledger_boundary_reference_redirects_proof_spec.rb (new)
    44 examples across 11 scenarios covering all acceptance criteria.

[T] Tests:
- 44 new reference redirects proof examples, 0 failures
- 956/956 full package suite examples, 0 failures
- All existing availability, settlement, and hydration specs remain green.

[R] Risks / next recommendations:
- find_raw_fact scans all facts in each raw store (O(n)): fine for proof but would need
  keyed or indexed lookup at production scale.
- original_store is "unknown" — tracking per-fact store provenance at write time would
  enable richer redirect records, but requires threading store name through source_fact_ids
  collection (currently just IDs, not ID+store pairs).
- :summary fidelity could additionally read :ledger_boundary_summaries to embed the
  actual summary fact_id and metrics_fact_id in the evidence. Currently it only returns
  the settlement_receipt_id from the redirect record. No tests require this extra step.
- Idempotency: duplicate compaction is prevented by compact! guard (raises unless status
  == :closed). Writing redirects twice for the same fact_id is therefore impossible in
  normal flow. If needed, the latest-by-transaction-time rule handles it cleanly.
```
