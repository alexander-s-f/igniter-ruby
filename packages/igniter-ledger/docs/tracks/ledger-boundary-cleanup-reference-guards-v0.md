# Track: Ledger Boundary Cleanup Reference Guards v0

Status date: 2026-05-04
Status: done
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Make cleanup planning reference-aware.

We now have proof layers for:

```text
boundary closure / settlement / compaction
source_fact_refs
fact redirects
fact-id index
relation edges
raw -> redirected edge transition
```

But `cleanup_plan` still only reasons about boundary lifecycle:

```text
open?
closed?
settled?
```

It does not yet enforce the safety rule from the compaction plan:

```text
fact is purge-eligible when external references are either absent or redirected
```

This slice should prove that a cleanup plan refuses to mark facts as purge-safe
while raw external relation edges still point at those facts.

Research question:

```text
Can cleanup planning block physical purge until external references have moved
from raw -> redirected?
```

Keep this proof-local to `examples/intelligent_ledger`.

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/intelligent-ledger/README.md`
4. `docs/intelligent-ledger/ledger-boundaries-compaction-plan.md`
5. `docs/tracks/ledger-boundary-settlement-proof-v0.md`
6. `docs/tracks/ledger-boundary-reference-redirects-v0.md`
7. `docs/tracks/ledger-boundary-source-fact-provenance-v0.md`
8. `docs/tracks/ledger-fact-id-index-v0.md`
9. `docs/tracks/ledger-relation-edge-redirect-projection-v0.md`
10. this track

Then inspect only the files named below unless blocked.

## Current Baseline

Current `AvailabilityBoundaryLedger#cleanup_plan`:

```text
blocked when:
  boundary is open
  boundary is closed but settlement_status != settled

ready when:
  all in-window boundaries are closed/settled
```

Current relation edge proof:

```text
:ledger_relation_edges
  ref_status: raw | redirected | unresolved
  to_fact_id
  to_boundary_key
  evidence
```

Known gap:

```text
cleanup_plan can be ready even when external relation edges still point at
raw source facts inside the boundary.
```

## Scope

Update `AvailabilityBoundaryLedger#cleanup_plan` so it can account for relation
edge guard state.

Suggested options:

```ruby
cleanup_plan(
  store: :order_events,
  before: cutoff,
  fidelity: :boundary,
  require_reference_redirects: true
)
```

Default may be `true` or `false`; choose the least disruptive option. If adding
the keyword would break many existing specs, default to `false` and add proof
specs with `true`. If safe, default to `true` because this is the intended
safety rule.

## Reference Guard Semantics

For each in-window boundary that is otherwise cleanup-eligible:

1. Inspect its `source_fact_ids`.
2. Find latest relation edges whose `to_fact_id` is one of those source ids.
3. Classify edge state:
   - `raw` -> blocking
   - `redirected` -> safe
   - `unresolved` -> blocking unless policy explicitly allows unresolved
4. If any blocking edge exists, cleanup plan returns `status: :blocked`.

Suggested blocking reason:

```text
:external_reference_redirect_required
```

Suggested plan fields:

```ruby
{
  blocking_relation_edges: [
    {
      edge_id: "...",
      to_fact_id: "...",
      ref_status: :raw,
      boundary_key: "..."
    }
  ],
  blocking_reasons: {
    boundary_key => :external_reference_redirect_required
  }
}
```

If existing `blocking_reasons` already maps boundary_key to one reason, and
multiple reasons exist, either:

- keep the first reason and add `blocking_reference_edges`, or
- change value to an Array of reasons only if existing specs can be updated
  clearly.

Prefer preserving existing shape and adding new fields.

## Required Behavior

### No external references

If a settled boundary has no relation edges to its source facts:

```text
cleanup_plan(..., require_reference_redirects: true) -> ready
```

### Raw external reference

If a relation edge points to a boundary source fact and latest edge status is
`raw`:

```text
cleanup_plan(..., require_reference_redirects: true) -> blocked
blocking reason includes external_reference_redirect_required
```

### Redirected external reference

After:

```ruby
ledger.refresh_relation_edges(assume_compacted: true)
```

latest edge status becomes `redirected`, and:

```text
cleanup_plan(..., require_reference_redirects: true) -> ready
```

### Unresolved edge

If latest edge status is `unresolved` and points to a source fact id or otherwise
claims that target:

```text
cleanup_plan(..., require_reference_redirects: true) -> blocked
```

This is conservative: unknown external references should not be ignored.

### Hydration / restart

Guard behavior should work on a fresh ledger:

```ruby
ledger2 = AvailabilityBoundaryLedger.new(store: same_store)
ledger2.hydrate_boundaries
ledger2.cleanup_plan(..., require_reference_redirects: true)
```

It is okay if edge lookup reads `:ledger_relation_edges` directly.

## Acceptance

- Full package test suite passes.
- Existing intelligent-ledger proof specs remain green.
- New specs live under `spec/igniter/store/intelligent_ledger/`.
- Existing cleanup_plan behavior remains compatible unless intentionally updated.
- Settled boundary with no external edges remains ready.
- Settled boundary with raw edge to a source fact is blocked when reference
  guards are enabled.
- Blocking plan includes relation edge details and reason
  `:external_reference_redirect_required`.
- After `refresh_relation_edges(assume_compacted: true)`, the same cleanup plan
  becomes ready.
- Multiple raw edges to the same boundary all appear in blocking relation edge
  details.
- Unresolved edge to a source fact blocks cleanup.
- Redirected edge does not block cleanup.
- Fresh ledger after `hydrate_boundaries` enforces the same guard using
  persisted edges.
- `refresh_relation_edges` remains idempotent.
- Track handoff is appended at the end of this file.

## Edge Cases To Cover

- Edge history has older raw edge and latest redirected edge: use latest only.
- Edge history has older redirected edge and latest raw edge: block.
- Boundary has empty `source_fact_ids`: no reference guard blocking.
- `require_reference_redirects: false` preserves old behavior, if this option is
  added.
- Mixed boundaries: one ready, one blocked by raw external edge -> whole plan
  blocked and reports the blocking boundary.

## Non-Goals

- No physical purge execution.
- No core retention engine rewrite.
- No protocol / HTTP / MCP endpoint.
- No persistent disk index.
- No Rust implementation.
- No generic relation engine.
- No Spark CRM integration.
- No public DSL.

## Suggested Files To Inspect

```text
examples/intelligent_ledger/availability_boundary_ledger.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_proof_spec.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_settlement_proof_spec.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_hydration_recovery_proof_spec.rb
spec/igniter/store/intelligent_ledger/ledger_relation_edge_redirect_projection_proof_spec.rb
docs/intelligent-ledger/ledger-boundaries-compaction-plan.md
docs/tracks/ledger-relation-edge-redirect-projection-v0.md
```

## Handoff

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/ledger-boundary-cleanup-reference-guards-v0
Status: done

[D] Decisions:
- cleanup_plan gains require_reference_redirects: false keyword (default false,
  preserving all existing caller behavior without changes).
- When true, for each settled in-window boundary: scan :ledger_relation_edges,
  take latest fact per edge_id, check ref_status. raw or unresolved → blocking.
  redirected → safe.
- Private raw_external_edges_for(boundary): groups history by key, takes latest,
  filters by source_fact_ids membership and blocking ref_status.
  Uses Set for O(1) source_id lookup; handles empty source_fact_ids (returns []).
- Added blocking_relation_edges field to plan result when require_reference_redirects
  is set ([] in ready plan, populated in blocked plan).
- blocking_reasons: existing shape preserved. Added :external_reference_redirect_required
  as new reason. No overlap with lifecycle reasons (settled = no lifecycle block).
- Hydration proof works without changes: hydrate_boundaries populates source_fact_ids;
  raw_external_edges_for reads :ledger_relation_edges directly from store.
- Constant collision between relation-edge and cleanup-guards specs silenced by
  adding `unless defined?` guards to both ABL/LB constant definitions.

[S] Shipped:
- examples/intelligent_ledger/availability_boundary_ledger.rb (updated)
    cleanup_plan: added require_reference_redirects: false keyword.
    New branch: checks settled in-window boundaries for raw/unresolved external edges.
    blocking_relation_edges field added to plan result.
    raw_external_edges_for(boundary): private helper — scans ledger_relation_edges.
- spec/igniter/store/intelligent_ledger/ledger_boundary_cleanup_reference_guards_proof_spec.rb (new)
    18 examples across 11 scenarios.
- spec/igniter/store/intelligent_ledger/ledger_relation_edge_redirect_projection_proof_spec.rb (minor)
    ABL/LB constant definitions guarded with unless defined? to prevent load-order warnings.

[T] Tests:
- 18 new examples, 0 failures
- 1048/1048 full package suite examples, 0 failures, 0 warnings
- All existing cleanup_plan, settlement, boundary, and hydration specs remain green.

[A] Acceptance anchor:
- Cleanup planning can say "not safe to purge yet; these external raw edges still
  point at boundary internals" and then become ready after the edges are redirected.
```
