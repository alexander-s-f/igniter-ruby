# Track: Ledger Relation Edge Redirect Projection v0

Status date: 2026-05-04
Status: done
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Prove that cross-fact relation edges survive boundary compaction.

We now have:

```text
source_fact_refs
ledger_fact_redirects
fact_by_id / fact_ref
resolve_ref(fact_id, fidelity:)
```

But relation links still need a proof:

```text
Order / Notification / Call / Schedule relation edge
  -> points to raw fact id

later:
  raw fact is compacted inside a LedgerBoundary

required:
  edge does not disappear
  edge becomes redirected with boundary evidence
```

This slice should add an app-local Intelligent Ledger proof for relation edges.
Do not rewrite the existing core `register_relation/resolve` API yet.

Research question:

```text
Can a relation edge move from raw -> redirected without losing explainability?
```

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/intelligent-ledger/README.md`
4. `docs/intelligent-ledger/ledger-boundaries-compaction-plan.md`
5. `docs/tracks/ledger-boundary-reference-redirects-v0.md`
6. `docs/tracks/ledger-boundary-source-fact-provenance-v0.md`
7. `docs/tracks/ledger-fact-id-index-v0.md`
8. this track

Then inspect only the files named below unless blocked.

## Current Baseline

Proof stack:

```text
AvailabilityBoundaryLedger
  close/settle/compact/hydrate
  source_fact_refs
  ledger_fact_redirects
  resolve_ref(fact_id, fidelity:)

IgniterStore
  fact_by_id
  fact_ref
```

Existing core relation API:

```ruby
store.register_relation(...)
store.resolve(...)
```

That API returns values and is not yet fidelity/redirect-aware. Leave it alone
unless a tiny helper is clearly needed.

## Scope

Add a proof-level relation edge projection under `examples/intelligent_ledger`.

Suggested store:

```text
:ledger_relation_edges
```

Suggested edge value:

```ruby
{
  "edge_id"       => "...",
  "from_store"    => "notifications",
  "from_key"      => "notification-1",
  "from_fact_id"  => "...",
  "to_store"      => "order_events",
  "to_key"        => "order-123",
  "to_fact_id"    => "...",
  "to_boundary_key" => nil,
  "ref_status"    => "raw",          # raw | redirected | unresolved
  "fidelity"      => "raw",          # raw | boundary | summary
  "evidence"      => {}
}
```

Keep the model compact. A small `RelationEdge` value object is welcome if it
keeps code cleaner, but do not build a generic relation engine.

## Suggested API

On `AvailabilityBoundaryLedger` or a tiny helper owned by it:

```ruby
ledger.link_fact(
  from_store: :notifications,
  from_key: "notification-1",
  from_fact_id: "...",
  to_fact_id: "...",
  relation: :notification_order_event
)

ledger.resolve_edge(edge_id, fidelity: :raw)
ledger.resolve_edge(edge_id, fidelity: :boundary)
ledger.refresh_relation_edges
```

Alternative names are fine if the behavior is clear.

## Edge State Semantics

### Raw

When `to_fact_id` is live:

```ruby
{
  status: :ok,
  ref_status: :raw,
  fidelity: :raw,
  to_fact: <Fact> # or compact fact_ref if cleaner
}
```

### Redirected

When raw detail is unavailable but boundary redirect evidence exists:

```ruby
{
  status: :ok,
  ref_status: :redirected,
  fidelity: :boundary,
  to_boundary_key: "...",
  evidence: {
    boundary_output_fact_id: "...",
    boundary_receipt_id: "...",
    settlement_receipt_id: "...",
    compaction_receipt_id: "..."
  }
}
```

### Unresolved

When neither raw fact nor redirect exists:

```ruby
{
  status: :unresolved,
  ref_status: :unresolved,
  to_fact_id: "..."
}
```

## Required Behavior

### Creating edges

Creating an edge should persist a relation edge fact.

If `to_fact_id` is live, the edge starts as:

```text
ref_status: raw
fidelity: raw
```

Use `store.fact_ref(to_fact_id)` to fill `to_store`, `to_key`, and metadata when
available.

If the target is unknown, persist the edge as unresolved rather than raising.

### Refreshing edges after compaction

After boundary compaction writes `:ledger_fact_redirects`, refreshing or
resolving the edge should detect:

```text
raw not accepted / assumed compacted
redirect exists
```

and produce:

```text
ref_status: redirected
fidelity: boundary
to_boundary_key: ...
evidence: ...
```

You can model raw detail unavailable using an explicit proof option, similar to
`resolve_ref(..., assume_compacted: true)`.

Suggested:

```ruby
ledger.resolve_edge(edge_id, fidelity: :boundary)
ledger.resolve_edge(edge_id, fidelity: :raw, assume_compacted: true)
ledger.refresh_relation_edges(assume_compacted: true)
```

Choose the least invasive implementation.

### Persistence / Restart

Edges and redirected state should survive restart:

```ruby
ledger2 = AvailabilityBoundaryLedger.new(store: same_store)
ledger2.hydrate_boundaries
ledger2.resolve_edge(edge_id, fidelity: :boundary)
```

It is acceptable if edge resolution reads persisted edge facts and redirect
facts directly without needing hydrated boundaries.

## Acceptance

- Full package test suite passes.
- Existing intelligent-ledger proof specs remain green.
- New specs live under `spec/igniter/store/intelligent_ledger/`.
- A relation edge can be created from one fact to another live raw fact.
- Edge creation uses `store.fact_ref` / `fact_by_id` and persists compact edge
  metadata without embedding full target payload.
- Resolving a live edge with `fidelity: :raw` returns raw status.
- After boundary compaction, resolving with boundary fidelity returns redirected
  status and boundary evidence.
- Raw fidelity does not silently downgrade; if raw is assumed compacted/unavailable,
  it returns a detail-unavailable/unresolved style response with evidence.
- `refresh_relation_edges` or equivalent updates persisted edge state
  `raw -> redirected`.
- Restart proof: fresh ledger can resolve persisted edge through redirect
  evidence.
- Unknown target fact creates/resolves as unresolved, not exception.
- Existing core `register_relation/resolve` behavior remains unchanged.
- Track handoff is appended at the end of this file.

## Edge Cases To Cover

- Multiple relation edges point to the same compacted fact: all redirect.
- Edge target fact exists but store mismatches expected `to_store`: do not return
  the wrong raw fact silently.
- Edge has stale raw metadata but redirect exists: boundary fidelity should
  prefer redirect evidence.
- Edge has no redirect and no raw fact: unresolved.
- `refresh_relation_edges` is idempotent.
- Edge record should keep enough previous metadata to explain transition:
  `previous_ref_status` or `ref_status_history` is optional, but at least the
  new persisted fact should show redirected evidence.

## Non-Goals

- No rewrite of core `register_relation/resolve`.
- No protocol / HTTP / MCP endpoint.
- No physical purge.
- No persistent disk index.
- No Rust implementation.
- No generic graph query language.
- No Spark CRM integration.
- No public DSL.

## Suggested Files To Inspect

```text
examples/intelligent_ledger/availability_boundary_ledger.rb
examples/intelligent_ledger/availability_ledger.rb
examples/intelligent_ledger/ledger_boundary.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_reference_redirects_proof_spec.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_source_fact_provenance_proof_spec.rb
spec/igniter/store/intelligent_ledger/ledger_fact_id_index_proof_spec.rb
lib/igniter/store/igniter_store.rb
spec/igniter/store/relation_rule_spec.rb
docs/intelligent-ledger/ledger-boundaries-compaction-plan.md
```

## Handoff

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/ledger-relation-edge-redirect-projection-v0
Status: done

[D] Decisions:
- All edge methods added to AvailabilityBoundaryLedger (proof-local; core
  register_relation/resolve left untouched).
- :ledger_relation_edges store; key = edge_id (SecureRandom.uuid).
- Edge value: edge_id, relation, from_store/key/fact_id, to_store/key/fact_id,
  to_boundary_key, ref_status (raw|redirected|unresolved), fidelity, evidence.
  to_store/to_key populated from fact_ref(to_fact_id) at creation time.
  Unknown target → ref_status: "unresolved", to_store: nil (not exception).
- resolve_edge delegates to resolve_ref for redirect/boundary semantics.
  Special case: for :raw fidelity without assume_compacted, checks fact_by_id
  first to handle live facts that have no redirect yet (resolve_ref(:raw)
  requires a redirect to exist; edges must also resolve for live uncompacted facts).
- refresh_relation_edges: groups edge history by key, takes latest per key,
  skips non-raw edges (idempotent), checks fact_by_id unless assume_compacted,
  reads latest_redirect, writes updated edge fact with redirected state.
  edge.transform_keys(&:to_s).merge(...) normalizes symbol keys (from store read)
  back to string keys before writing updated edge value.
- Restart proof: resolve_edge reads :ledger_relation_edges and :ledger_fact_redirects
  directly — no hydrate_boundaries required.

[S] Shipped:
- examples/intelligent_ledger/availability_boundary_ledger.rb (updated)
    link_fact: creates :ledger_relation_edges entry using fact_ref for metadata.
    resolve_edge: live-fact shortcut + resolve_ref delegation + edge status mapping.
    refresh_relation_edges: scans raw edges, updates to redirected when redirect exists.
- spec/igniter/store/intelligent_ledger/ledger_relation_edge_redirect_projection_proof_spec.rb (new)
    17 examples across 9 scenarios.

[T] Tests:
- 17 new examples, 0 failures
- 1030/1030 full package suite examples, 0 failures
- All existing proof specs remain green (additive change, no breaking modifications).

[A] Acceptance anchor:
- An edge pointing to a raw fact can transition raw → redirected, preserving
  boundary evidence instead of disappearing or silently lying.
```
