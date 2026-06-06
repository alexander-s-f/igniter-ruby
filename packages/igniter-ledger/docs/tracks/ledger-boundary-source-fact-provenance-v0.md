# Track: Ledger Boundary Source Fact Provenance v0

Status date: 2026-05-04
Status: done
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Upgrade the Intelligent Ledger boundary proof from bare source fact IDs to
structured source fact references.

`ledger-boundary-reference-redirects-v0` proved that compacted facts can resolve
through boundary evidence, but redirect records still contain:

```text
original_store: "unknown"
```

because boundary state only knows:

```ruby
source_fact_ids: ["fact-1", "fact-2"]
```

This slice should prove that boundary provenance can carry enough information
to answer:

```text
which store did this source fact come from?
what role did it play in the derivation?
was it direct input, override, order event, or carried state?
```

Keep this as proof code under `examples/intelligent_ledger`; do not promote it
to core/public API yet.

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/intelligent-ledger/README.md`
4. `docs/intelligent-ledger/ledger-boundaries-compaction-plan.md`
5. `docs/tracks/ledger-boundary-availability-proof-v0.md`
6. `docs/tracks/ledger-boundary-settlement-proof-v0.md`
7. `docs/tracks/ledger-boundary-hydration-recovery-v0.md`
8. `docs/tracks/ledger-boundary-reference-redirects-v0.md`
9. this track

Then inspect only the example/spec files named below unless blocked.

## Current Baseline

Current flow:

```text
AvailabilityLedger#compute_snapshot
  -> AvailabilityDeriver.derive(..., source_fact_ids:)
  -> snapshot value stores derived_from_fact_ids
  -> LedgerBoundary.close!(source_fact_ids:)
  -> compact_boundary writes redirects with original_store: "unknown"
```

Known gap:

```text
source_fact_ids are not enough for durable relation/reference consistency.
```

## Scope

Add structured source refs while preserving compatibility with current tests.

Suggested shape:

```ruby
{
  "id"    => "fact-id",
  "store" => "order_events",
  "role"  => "order_event",
  "key"   => "order-123",          # optional but useful if easy
  "type"  => "created"             # optional domain detail if easy
}
```

Canonical proof field names:

```text
source_fact_refs
derived_from_fact_refs
```

Backward-compatible fields should remain for now:

```text
source_fact_ids
derived_from_fact_ids
```

The goal is additive migration, not breaking the prior proof stack.

## Source Ref Rules

Minimum mapping for availability proof:

```text
:availability_templates  -> role: "template"
:availability_overrides  -> role: "override"
:order_events            -> role: "order_event"
```

Every ref should include at least:

```text
id
store
role
```

Optional fields:

```text
key
valid_time
transaction_time
```

Only add optional fields if they are easy and do not make the proof noisy.

## Required Behavior

### Availability snapshot

`AvailabilityLedger#compute_snapshot` should produce both:

```ruby
snapshot_fact.value[:derived_from_fact_ids]
snapshot_fact.value[:derived_from_fact_refs]
```

The old ID array remains for compatibility.

### LedgerBoundary

`LedgerBoundary` should expose both:

```ruby
boundary.source_fact_ids
boundary.source_fact_refs
```

`source_fact_ids` may be derived from refs, but existing callers/specs should
continue to work.

`result_hash` should remain stable enough for existing specs. If it changes
because refs are part of the hash, update tests intentionally and document the
decision. Prefer keeping hash semantics based on output + sorted IDs +
rule_version for this proof, and add refs as provenance rather than result
identity.

### Persisted boundary records and receipts

Persist both:

```text
source_fact_ids
source_fact_refs
```

Hydration must restore both fields.

### Redirects

`compact_boundary` should use `source_fact_refs` when writing
`:ledger_fact_redirects`.

Redirect entries should no longer use `"unknown"` when ref provenance is
available:

```ruby
{
  "original_fact_id" => ref["id"],
  "original_store"   => ref["store"],
  "reference_role"   => "included_in_boundary",
  "source_role"      => ref["role"]
}
```

Keep `reference_role` for boundary evidence semantics. Add `source_role` for
domain/provenance role.

### Raw lookup

`resolve_ref(..., fidelity: :raw)` should prefer redirect provenance:

```text
if redirect has original_store:
  scan/read that store only
else:
  fall back to RAW_PROOF_STORES scan
```

This keeps the proof simple while proving the right direction.

## Acceptance

- Full package test suite passes.
- Existing availability, boundary, settlement, hydration, and redirect specs
  remain green.
- New specs live under `spec/igniter/store/intelligent_ledger/`.
- Snapshot values include `derived_from_fact_refs` with id/store/role.
- Snapshot values still include `derived_from_fact_ids`.
- Boundary exposes `source_fact_refs`.
- Boundary still exposes `source_fact_ids`.
- Boundary records and closure receipts persist `source_fact_refs`.
- Hydration restores `source_fact_refs` and preserves `source_fact_ids`.
- Compaction redirects use `original_store` from refs, not `"unknown"`, when
  refs are present.
- Redirects include `source_role`.
- `resolve_ref(..., fidelity: :raw)` can find raw fact using redirect
  `original_store`.
- Backward compatibility: hydrating an old-style boundary record with only
  `source_fact_ids` still works and produces fallback refs or empty refs
  without crashing.
- Track handoff is appended at the end of this file.

## Edge Cases To Cover

- Mixed refs: one source ref missing store falls back to `"unknown"` or fallback
  scan, but does not crash.
- Old persisted boundary record has `source_fact_ids` only.
- Empty source refs / empty source ids.
- Duplicate source refs collapse consistently by id.
- Redirect for a template fact has `original_store: "availability_templates"`.
- Redirect for an order event has `original_store: "order_events"` if the test
  setup includes order facts.

## Non-Goals

- No production fact-id index yet.
- No physical purge.
- No relation index implementation.
- No Ledger Open Protocol operation.
- No HTTP/MCP endpoint.
- No Rust implementation.
- No public DSL.
- No Spark CRM integration.

## Suggested Files To Inspect

```text
examples/intelligent_ledger/availability_ledger.rb
examples/intelligent_ledger/availability_deriver.rb
examples/intelligent_ledger/ledger_boundary.rb
examples/intelligent_ledger/availability_boundary_ledger.rb
spec/igniter/store/intelligent_ledger/availability_snapshot_proof_spec.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_proof_spec.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_hydration_recovery_proof_spec.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_reference_redirects_proof_spec.rb
docs/tracks/ledger-boundary-reference-redirects-v0.md
```

## Handoff

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/ledger-boundary-source-fact-provenance-v0
Status: done

[D] Decisions:
- AvailabilityDeriver#derive gains source_fact_refs: keyword (default nil).
  The deriver stores derived_from_fact_refs alongside derived_from_fact_ids.
  Old callers that don't pass source_fact_refs get an empty refs array — safe.
- AvailabilityLedger#compute_snapshot builds source_refs in parallel with
  source_ids: template→"availability_templates"/role:"template",
  override→"availability_overrides"/role:"override",
  order→"order_events"/role:"order_event". Includes optional "key" field.
- LedgerBoundary.close! gains source_fact_refs: [] keyword. Refs are normalized
  to string keys via transform_keys(&:to_s) at close time so in-memory state is
  always string-keyed regardless of store round-trip.
- result_hash kept unchanged (output + sorted IDs + rule_version). Refs are
  provenance metadata, not result identity. Existing result_hash tests pass.
- compact_boundary uses source_fact_refs when any? present, writing redirects
  with original_store/source_role from provenance. Falls back to bare IDs with
  "unknown" store for old-style boundaries (backward compat).
- resolve_ref(:raw) passes redirect[:original_store] as store_hint to
  find_raw_fact. When hint is a known store name (not "unknown" or nil),
  scans only that store. Falls back to RAW_PROOF_STORES scan otherwise.
- restore_from_record! normalizes persisted refs (symbol keys from store) back
  to string keys via transform_keys(&:to_s). Old records without source_fact_refs
  silently produce [] — no crash.
- boundary_record_value, closure receipt, compaction receipt all persist
  source_fact_refs alongside source_fact_ids.

[S] Shipped:
- examples/intelligent_ledger/availability_deriver.rb (updated)
    derive: added source_fact_refs: nil keyword, outputs derived_from_fact_refs.
- examples/intelligent_ledger/availability_ledger.rb (updated)
    compute_snapshot: builds source_refs (id/store/role/key) in parallel with
    source_ids; passes source_fact_refs: to deriver; adds source_fact_refs to
    receipt; adds source_fact_refs to snapshot_derivation_metadata.
- examples/intelligent_ledger/ledger_boundary.rb (updated)
    attr_reader :source_fact_refs added; initialized to [].freeze.
    close!: accepts source_fact_refs: [], normalizes to string keys, deduplicates.
    restore_from_record!: restores source_fact_refs from boundary_record,
    normalizing symbol → string keys; falls back to [] if absent.
- examples/intelligent_ledger/availability_boundary_ledger.rb (updated)
    close_boundary: extracts derived_from_fact_refs from snapshot, passes to close!;
    closure receipt includes source_fact_refs.
    boundary_record_value: includes source_fact_refs.
    compact_boundary: if refs present, uses ref store+role for redirect entries;
    else falls back to bare IDs with "unknown"; cleanup receipt includes refs.
    find_raw_fact(fact_id, store_hint: nil): targeted lookup when hint is known.
    resolve_ref: passes store_hint from redirect[:original_store] to find_raw_fact.
- spec/igniter/store/intelligent_ledger/ledger_boundary_source_fact_provenance_proof_spec.rb (new)
    28 examples across 12 scenarios.

[T] Tests:
- 28 new provenance proof examples, 0 failures
- 984/984 full package suite examples, 0 failures
- All existing availability, boundary, settlement, hydration, and redirect specs
  remain green (additive change, no breaking modifications).

[R] Risks / next recommendations:
- derived_from_fact_refs is written into snapshot_value with string keys, but
  store normalizes to symbol keys on read-back. The ref normalization in close!
  and restore_from_record! handles this, but callers who read snapshot_fact.value
  directly will see symbol-keyed refs (e.g. ref[:store], not ref["store"]).
- The "key" field in refs is included (template.key = technician_id, etc.) but
  not yet tested for fidelity — future tests could verify it routes correctly.
- order_facts are all collected (not just active_reservations) as source refs,
  matching the existing source_ids behavior. Cancelled orders are refs but not
  active_reservations — intentional: provenance tracks all facts that informed
  the derivation, not just those that changed the output.
- snapshot_derivation_metadata now includes source_fact_refs. If the store's
  derivation metadata API does not support arbitrary keys, this could fail in a
  non-proof environment — not applicable to the current proof store.
```
