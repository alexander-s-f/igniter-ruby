# Track: Ledger Fact ID Index v0

Status date: 2026-05-04
Status: done
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Remove the next proof-level scan from Intelligent Ledger reference resolution.

After `ledger-boundary-source-fact-provenance-v0`, boundary redirects know:

```text
original_fact_id
original_store
source_role
```

but `resolve_ref(..., fidelity: :raw)` still finds raw facts by scanning store
history:

```ruby
@store.history(store: original_store).find { |f| f.id == fact_id }
```

This slice should introduce a small fact-id lookup index and use it from the
Intelligent Ledger proof. The index should be package-level enough to prove the
shape, but not yet part of Ledger Open Protocol / HTTP / MCP.

Research question:

```text
Can the store answer "where is fact id X now?" without scanning histories,
and can boundary redirect resolution use that answer?
```

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/intelligent-ledger/README.md`
4. `docs/intelligent-ledger/ledger-boundaries-compaction-plan.md`
5. `docs/tracks/ledger-boundary-reference-redirects-v0.md`
6. `docs/tracks/ledger-boundary-source-fact-provenance-v0.md`
7. this track

Then inspect only the files named below unless blocked.

## Current Baseline

Relevant current code:

```text
IgniterStore
  write / append / protected replay / rebuild_log!
  scope_index
  partition_index
  no fact_id index

AvailabilityBoundaryLedger
  find_snapshot_value(fact_id)
    scans :availability_snapshots

  find_raw_fact(fact_id, store_hint:)
    scans store_hint store or RAW_PROOF_STORES
```

Known gap:

```text
source refs know the store, but lookup remains O(store history).
```

## Scope

Add an internal fact-id index to `IgniterStore`.

Suggested public Ruby methods:

```ruby
store.fact_by_id(fact_id)
store.fact_ref(fact_id)
```

Suggested behavior:

```ruby
fact = store.fact_by_id("uuid")
# => Fact | nil

ref = store.fact_ref("uuid")
# => { id:, store:, key:, transaction_time:, valid_time:, value_hash: } | nil
```

If a method name already fits local style better, choose that name, but keep it
simple and documented in tests. Prefer a tiny read API over exposing index
internals.

## Index Semantics

Index shape:

```text
@fact_id_index
  fact_id -> Fact
```

Required maintenance points:

- `write` indexes the written fact.
- `append` indexes the appended fact.
- `replay(fact)` indexes replayed facts when `IgniterStore.open(path)` restores
  from backend.
- `rebuild_log!(new_facts)` rebuilds the index from surviving facts after
  retention compaction.

The index reflects currently live facts in the in-memory store.

When core retention compaction drops facts:

```text
fact_by_id(dropped_fact_id) -> nil
```

Boundary redirect records may still preserve evidence separately. That is the
important distinction:

```text
raw fact lookup: live fact-id index
boundary evidence lookup: ledger_fact_redirects
```

## Intelligent Ledger Integration

Update `AvailabilityBoundaryLedger`:

### Snapshot hydration

Replace:

```ruby
@store.history(store: :availability_snapshots).find { |f| f.id == fact_id }
```

with:

```ruby
@store.fact_by_id(fact_id)&.value
```

Only accept the result if the returned fact is from `:availability_snapshots`.
If it is not, return nil or warning-level fallback; do not trust a wrong-store
fact.

### Raw reference resolution

Replace scan-based `find_raw_fact` with fact-id index lookup:

```ruby
fact = @store.fact_by_id(fact_id)
return fact if fact && store_hint_ok?(fact.store, store_hint)
```

Semantics:

- if `store_hint` is known and the indexed fact is in that store, return it
- if `store_hint` is known and the indexed fact is in a different store, return
  nil / detail unavailable rather than silently accepting the mismatch
- if `store_hint` is nil or `"unknown"`, return the indexed fact if present
- no `RAW_PROOF_STORES` scan needed for new path

Keep `RAW_PROOF_STORES` only if needed for backward compatibility tests, but
the new proof should show index lookup is the normal path.

## Acceptance

- Full package test suite passes.
- Existing intelligent-ledger proof specs remain green.
- New specs live under `spec/igniter/store/` and/or
  `spec/igniter/store/intelligent_ledger/`.
- `IgniterStore#fact_by_id` returns the exact Fact object written by `write`.
- `IgniterStore#fact_by_id` returns the exact Fact object written by `append`.
- `IgniterStore#fact_ref` returns compact metadata:
  - id
  - store
  - key
  - transaction_time
  - valid_time
  - value_hash
- Unknown fact id returns nil.
- File-backed `IgniterStore.open(path)` rebuilds the fact-id index during replay.
- Retention compaction / `rebuild_log!` removes dropped fact ids from the index
  and keeps surviving fact ids.
- `AvailabilityBoundaryLedger#find_snapshot_value` uses the fact-id index.
- `AvailabilityBoundaryLedger#resolve_ref(..., fidelity: :raw)` uses the
  fact-id index and respects `original_store` mismatch.
- Redirect resolution still returns `:detail_unavailable` when raw is absent
  but redirect evidence exists.
- Track handoff is appended at the end of this file.

## Edge Cases To Cover

- `fact_by_id(nil)` or blank id returns nil, not an exception.
- Store hint mismatch:

```text
redirect says original_store=order_events
indexed fact has store=availability_templates
-> raw lookup must not return the wrong fact
```

- Replay duplicate fact ids should keep the latest replayed object for that id
  or preserve the first object. Pick one deterministic rule and document it.
  Normal writes generate unique ids, so this is mainly replay/corruption hygiene.
- `fact_ref` should not expose the full value payload.
- Coercion hooks should not affect `fact_by_id`; it returns raw Fact, like
  history paths do before value coercion wrapping.

## Non-Goals

- No persistent on-disk index file.
- No segmented backend index.
- No protocol / HTTP / MCP endpoint.
- No global cross-process index.
- No Rust implementation.
- No physical boundary purge.
- No public DSL.
- No Spark CRM integration.

## Suggested Files To Inspect

```text
lib/igniter/store/igniter_store.rb
lib/igniter/store/fact_log.rb
lib/igniter/store/fact.rb
spec/igniter/store/igniter_store_spec.rb
examples/intelligent_ledger/availability_boundary_ledger.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_reference_redirects_proof_spec.rb
spec/igniter/store/intelligent_ledger/ledger_boundary_source_fact_provenance_proof_spec.rb
docs/tracks/ledger-boundary-source-fact-provenance-v0.md
```

## Handoff

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/ledger-fact-id-index-v0
Status: done

[D] Decisions:
- @fact_id_index added to IgniterStore (not FactLog). Hash {fact_id => Fact}.
  Maintained on write, append, protected replay, and rebuild_log!.
  rebuild_log! rebuilds the index from surviving facts via each_with_object.
  NATIVE extension unaffected: IgniterStore always intercepts write/append.
- fact_by_id(fact_id): returns raw Fact or nil; nil/blank id guard; no coercion.
- fact_ref(fact_id): returns compact metadata {id, store, key, transaction_time,
  valid_time, value_hash} — no value payload exposed.
- find_snapshot_value: replaced history scan with fact_by_id; rejects result if
  fact.store != :availability_snapshots.
- find_raw_fact: replaced RAW_PROOF_STORES scan with fact_by_id; store_hint
  mismatch returns nil (fact in wrong store is not returned).
- RAW_PROOF_STORES constant kept in the module (used by the constant comment)
  but find_raw_fact no longer uses it for the new code path.

[S] Shipped:
- lib/igniter/store/igniter_store.rb (updated)
    @fact_id_index initialized in initialize.
    write and append index fact after @log.append.
    replay indexes fact after @log.replay.
    rebuild_log! rebuilds @fact_id_index from new_facts.
    fact_by_id and fact_ref added as public methods.
- examples/intelligent_ledger/availability_boundary_ledger.rb (updated)
    find_snapshot_value: uses @store.fact_by_id; store guard.
    find_raw_fact: uses @store.fact_by_id + store_hint mismatch rejection.
- spec/igniter/store/igniter_store_fact_id_index_spec.rb (new)
    15 examples: write/append indexing, nil/blank safety, coercion non-interference,
    fact_ref metadata shape, compaction removes dropped ids, file-backed replay.
- spec/igniter/store/intelligent_ledger/ledger_fact_id_index_proof_spec.rb (new)
    14 examples across 7 scenarios: index used in snapshot hydration, resolve_ref(:raw)
    via index, store_hint mismatch rejection, boundary redirect evidence when raw absent,
    file-backed replay rebuilds index, rebuild_log! consistency, nil/blank safety.

[T] Tests:
- 29 new examples, 0 failures
- 1013/1013 full package suite examples, 0 failures
- All existing proof specs remain green (additive change, no breaking modifications).

[A] Acceptance anchor:
- Given a fact id, the store answers "is this raw fact still live, and where?"
  without scanning histories. If it is not live, boundary redirect evidence still
  explains what happened to it.
```
