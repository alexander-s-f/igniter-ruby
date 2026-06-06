# Track: Ledger Cleanup Execution + Edge Index v0

Status date: 2026-05-04
Status: done
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Take the next larger vertical slice for boundary cleanup:

```text
reference-safe cleanup plan
  -> indexed relation-edge guard
  -> durable cleanup execution receipt
  -> still no physical purge
```

This is an x2 slice on purpose. The two parts are connected:

1. Cleanup guards should not scan the whole relation-edge history forever.
2. A ready cleanup plan should become an auditable operation with a durable
   receipt before we ever allow physical deletion.

Keep this proof-local to `examples/intelligent_ledger`.

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/intelligent-ledger/README.md`
4. `docs/intelligent-ledger/ledger-boundaries-compaction-plan.md`
5. `docs/tracks/ledger-boundary-cleanup-reference-guards-v0.md`
6. `docs/tracks/ledger-relation-edge-redirect-projection-v0.md`
7. `docs/tracks/ledger-fact-id-index-v0.md`
8. this track

Then inspect only the files needed for this track.

## Current Baseline

Already proven:

```text
boundaries can close and settle
source facts are captured in boundary receipts
facts can redirect to compacted boundaries
relation edges can move raw -> redirected
cleanup_plan can block when raw/unresolved external edges still target source facts
```

Known gap:

```text
raw_external_edges_for(boundary)
  scans all :ledger_relation_edges history
  groups by edge key
  filters by boundary.source_fact_ids
```

That is correct for the proof, but not the right shape for a ledger that may
stream many facts and many relation edges.

Second known gap:

```text
cleanup_plan is only a plan
```

It does not yet produce a durable execution receipt. Before physical purge, we
need a stable record saying what the system decided, what guards were checked,
and which detail would be eligible for removal.

## Scope A: Relation Edge Target Index

Add a proof-local access path for relation-edge guards.

Suggested shape:

```text
:ledger_relation_edge_targets
  key: to_fact_id
  value:
    to_fact_id
    edge_id
    from_store
    from_fact_id
    to_store
    to_boundary_key
    ref_status
    relation
    evidence
```

The exact store name can change if a better local naming pattern already exists,
but the direction matters:

```text
to_fact_id -> latest edge states that target this fact
```

Required behavior:

- `link_fact` writes or updates the target index when it writes a relation edge.
- `refresh_relation_edges` updates the target index when an edge moves
  `raw -> redirected` or `unresolved`.
- Cleanup guard lookup uses the target index path instead of scanning all
  relation-edge history.
- Existing `:ledger_relation_edges` remains the canonical edge history.
- The target index is an access path, not a competing source of truth.

Optional but useful:

```ruby
rebuild_relation_edge_target_index
```

This can replay `:ledger_relation_edges` into the index for recovery or proof
setup. Add it only if it keeps restart/idempotency tests clean.

## Scope B: Cleanup Execution Receipt

Add a proof method that turns a ready cleanup plan into a durable receipt.

Suggested API, choose the least awkward local spelling:

```ruby
execute_cleanup_plan(plan)
```

or:

```ruby
execute_cleanup(
  store: :order_events,
  before: cutoff,
  fidelity: :boundary,
  require_reference_redirects: true
)
```

The operation must not physically delete facts in this slice.

It should write to a new history store, for example:

```text
:ledger_cleanup_execution_receipts
```

Avoid overloading existing boundary compaction receipts. This receipt is about
cleanup execution, not boundary creation.

Suggested receipt fields:

```ruby
{
  status: :executed_noop,
  plan_hash: "...",
  store: :order_events,
  before: cutoff,
  fidelity: :boundary,
  require_reference_redirects: true,
  expected_detail_status: :purged,
  boundary_keys: [...],
  receipts_to_keep: [...],
  blocking_relation_edges_count: 0,
  relation_guard: {
    checked: true,
    raw_edges: 0,
    unresolved_edges: 0,
    redirected_edges: 3
  },
  executed_at: Time.now.utc
}
```

If the plan is blocked, the execution path should not write a successful
receipt. It may either return a blocked result or write a rejected receipt. Pick
one policy and document it in the handoff.

Preferred blocked result:

```ruby
{
  status: :blocked,
  reason: :plan_not_ready,
  blocking_boundaries: [...],
  blocking_relation_edges: [...]
}
```

## Idempotency

Execution should be idempotent.

Recommended approach:

```text
plan_hash = stable hash of the cleanup plan payload
receipt key = plan_hash
```

Running the same ready plan twice should not append two successful execution
receipts. The second call should return the existing receipt or a result that
clearly says:

```text
deduplicated: true
```

This matters because cleanup execution will eventually become an operator or
server operation that may be retried.

## Required Behavior

### Indexed guard parity

For all existing cleanup-reference-guard scenarios:

```text
old scan semantics == new indexed lookup semantics
```

Cases:

- no external edges -> ready
- raw edge to boundary source fact -> blocked
- unresolved edge to boundary source fact -> blocked
- redirected edge -> ready
- multiple edges to the same source fact -> all relevant blockers reported
- fresh ledger after hydrate/replay -> same guard result

### Guard index updates

When `link_fact` creates an edge:

```text
edge target index includes that edge under to_fact_id
```

When `refresh_relation_edges(assume_compacted: true)` redirects the edge:

```text
edge target index latest state is redirected
```

### Execution receipt

For a ready plan:

```text
execute_cleanup_plan(plan) -> executed_noop
:ledger_cleanup_execution_receipts has durable receipt
```

For a blocked guarded plan:

```text
execute_cleanup_plan(plan) -> blocked
no successful receipt is written
```

After edge refresh makes the plan ready:

```text
execute_cleanup_plan(new_plan) -> executed_noop
```

### Restart / hydration

A fresh ledger over the same store should be able to observe the execution
receipt and preserve idempotency:

```ruby
ledger2 = AvailabilityBoundaryLedger.new(store: same_store)
ledger2.execute_cleanup_plan(plan)
# returns existing/deduplicated receipt, not a duplicate success record
```

## Acceptance

- Full package test suite passes.
- Existing intelligent-ledger proof specs remain green.
- New specs live under `spec/igniter/store/intelligent_ledger/`.
- `cleanup_plan(..., require_reference_redirects: true)` no longer depends on a
  full scan of `:ledger_relation_edges` for normal guard lookup.
- Target-index behavior is covered for create, redirect, multiple edges, and
  fresh-ledger recovery.
- Cleanup execution writes a durable receipt for ready plans.
- Cleanup execution refuses blocked plans.
- Execution is idempotent by stable plan hash or equivalent deterministic key.
- No physical purge is implemented.
- No core protocol, HTTP, MCP, or Rust implementation changes are required for
  this slice.
- Track handoff is appended at the end of this file.

## Non-Goals

- Do not delete fact detail from WAL files.
- Do not rewrite core relation APIs.
- Do not promote cleanup execution to Ledger Open Protocol yet.
- Do not add server endpoints for cleanup.
- Do not move this proof into Rust yet.

## Risks / Watch Points

- The edge target index must remain an access path. If it disagrees with
  canonical `:ledger_relation_edges`, canonical edge history wins.
- If blocked execution writes rejected receipts, make sure rejected receipts do
  not interfere with successful idempotency later after guards pass.
- If plan hashing includes volatile fields, idempotency will fail. Exclude
  generated timestamps from the stable hash.
- This slice still validates safety at plan/execution time only. Later physical
  purge will need a stronger revalidation step immediately before deletion.

## Handoff

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/ledger-cleanup-execution-and-edge-index-v0
Status: done

[D] Decisions:
- Target index key = to_fact_id; multiple edges to the same fact accumulate as
  separate history entries under that key, each carrying edge_id in value.
  raw_external_edges_for groups by edge_id within that history to get latest state
  per edge, then filters for blocking statuses. Full :ledger_relation_edges scan
  is no longer needed for guard lookup.
- link_fact now writes to both :ledger_relation_edges (canonical) and
  :ledger_relation_edge_targets (access path). refresh_relation_edges does the
  same when transitioning raw → redirected. The target index is never consulted
  as source of truth; canonical history always wins in a conflict.
- rebuild_relation_edge_target_index added as public method: replays latest edge
  per edge_id from :ledger_relation_edges into the index. Idempotent (appends
  latest state; older entries remain in history). Useful for disaster recovery
  or proof-setup on a store that only has canonical history.
- execute_cleanup_plan(plan) accepts the result of cleanup_plan. Blocked plan →
  returns { status: :blocked, reason: :plan_not_ready } without writing a
  receipt. Ready plan → writes to :ledger_cleanup_execution_receipts keyed by
  stable plan hash.
- Idempotency key = SHA256 of [store, before, fidelity, require_reference_redirects,
  sorted(receipts_to_keep)]. Volatile fields (executed_at) are excluded from the
  hash. Second call for the same plan returns deduplicated: true without writing
  a new receipt record.
- cleanup_plan result now includes fidelity: and require_reference_redirects:
  fields (additive; no existing specs required updating). These fields are used
  by execute_cleanup_plan to embed in the receipt.
- Blocked execution does not write rejected receipts. A blocked result has no
  receipt in the store; this does not interfere with later successful idempotency
  for a ready plan derived from the same cleanup scope.
- Existing Scenario 4 in ledger_boundary_cleanup_reference_guards_proof_spec.rb
  was updated to write to both :ledger_relation_edges AND :ledger_relation_edge_targets
  when manually simulating an edge. This correctly mirrors what link_fact does
  and is the expected pattern for direct-write tests now that the index is the
  access path.

[S] Shipped:
- examples/intelligent_ledger/availability_boundary_ledger.rb (updated)
    require "digest" added.
    cleanup_plan: result now includes fidelity: and require_reference_redirects:.
    link_fact: writes to :ledger_relation_edge_targets after canonical write.
    refresh_relation_edges: writes to :ledger_relation_edge_targets when redirecting.
    rebuild_relation_edge_target_index: public method, replays from canonical history.
    execute_cleanup_plan: public method, writes durable receipt or returns blocked.
    raw_external_edges_for (private): replaced full scan of :ledger_relation_edges
      with indexed lookup from :ledger_relation_edge_targets.
    write_relation_edge_target (private): shared helper for index writes.
    stable_plan_hash (private): SHA256-based idempotency key for execution receipts.
    Store layout comment updated with two new stores.
- spec/igniter/store/intelligent_ledger/ledger_cleanup_execution_and_edge_index_proof_spec.rb (new)
    27 examples across 10 describe groups (Scope A + Scope B).
- spec/igniter/store/intelligent_ledger/ledger_boundary_cleanup_reference_guards_proof_spec.rb (minor)
    Scenario 4 updated to write the unresolved edge to both canonical store and
    target index, reflecting the correct pattern for direct-write edge simulation.

[T] Tests:
- 27 new examples, 0 failures
- 1075/1075 full package suite examples, 0 failures, 0 warnings
- All existing proof specs, cleanup guard specs, and settlement/hydration specs
  remain green.

[R] Risks / next recommendations:
- The target index is an access path. Any code path that writes to
  :ledger_relation_edges directly (without going through link_fact /
  refresh_relation_edges) must also write to :ledger_relation_edge_targets, or
  run rebuild_relation_edge_target_index afterward. The updated Scenario 4 test
  now documents this expectation.
- Blocked execution receipts are not written. If the policy ever changes to write
  rejected receipts, ensure their presence does not falsely trigger idempotency
  for a later successful execution of the same scope.
- The stable_plan_hash includes receipts_to_keep (sorted boundary receipt fact IDs).
  Adding new boundaries between two cleanup_plan calls changes the hash, which
  is correct. Callers that cache a plan and execute it later should be aware of
  this.
- physical purge remains the next major slice. The execute_cleanup_plan receipt
  should be treated as a "commit" record; actual deletion will need to re-validate
  guard state immediately before each fact is removed.
```
