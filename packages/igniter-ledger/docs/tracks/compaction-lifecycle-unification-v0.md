# Track: Compaction Lifecycle Unification v0

Status date: 2026-05-04
Status: done
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Make compaction one coherent lifecycle instead of several competing deletion
mechanisms.

We now have several working primitives:

```text
IgniterStore#compact
  retention policy over hot FactLog

AvailabilityBoundaryLedger#compact_boundary
  semantic boundary compaction, redirects, logical detail_status

IgniterStore#prune_fact_ids
  exact fact-id removal with FileBackend replay barrier

SegmentedFileBackend#purge!
  physical sealed-segment deletion by storage policy

AvailabilityBoundaryLedger#purge_cleanup_execution
  boundary-safe physical detail purge
```

These should not become five different compaction systems. This slice should
establish one vocabulary, one safety shape, and a common receipt/read model
while preserving the specialized executors.

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/intelligent-ledger/ledger-boundaries-compaction-plan.md`
4. `docs/tracks/ledger-cleanup-execution-and-edge-index-v0.md`
5. `docs/tracks/ledger-boundary-physical-purge-barrier-v0.md`
6. this track

Then inspect only the files needed for this track.

## Core Decision

Use one lifecycle vocabulary:

```text
compact
  semantic lifecycle verb:
  reduce retained detail while preserving truth/proof

prune
  exact fact-level executor:
  remove known fact ids from the hot logical log

purge
  physical storage executor:
  remove whole storage artifacts such as sealed segments
```

Rule:

```text
No new deletion/compaction API should bypass the compaction lifecycle.
```

Executors can remain specialized, but their plans and receipts should normalize
into one inspectable compaction activity stream.

## Important Bug Pressure

The physical purge slice proved that normal `FileBackend#write_snapshot` is not
a prune barrier because WAL replay can resurrect dropped facts.

Check whether `IgniterStore#compact` still has the same risk:

```text
compact_store
  -> write compaction receipt
  -> rebuild_log!(survivors)
  -> backend.write_snapshot(@log.all_facts)
```

If the WAL remains intact, retention-compacted facts can resurrect after reopen.
This slice should close that gap or explicitly block unsafe durable compaction.

## Scope A: Retention Compact Uses The Safe Lifecycle

Update `IgniterStore#compact` / `compact_store` so retention compaction does not
use an unsafe checkpoint as its durable barrier.

Preferred behavior:

```text
retention compact
  -> compute keep/drop
  -> write existing :__compaction_receipts summary
  -> exact-prune dropped fact ids through the same safe path as prune_fact_ids
  -> durable replay barrier when FileBackend is present
```

You may refactor internals to avoid double receipts if needed, but keep the
public return shape compatible unless there is a clear reason to improve it.

Required backend behavior:

- In-memory store: retention compact still works.
- FileBackend: compacted facts do not resurrect after close/reopen.
- SegmentedFileBackend: exact retention compaction must not silently pretend to
  be durable if exact segment rewrite is unsupported.

Acceptable SegmentedFileBackend behavior for this slice:

```text
IgniterStore#compact with SegmentedFileBackend -> unsupported / blocked
```

Segment-level `SegmentedFileBackend#purge!` remains a separate executor under
the same lifecycle vocabulary.

## Scope B: Compaction Activity Read Model

Add a compact read model that lets operators and future protocol surfaces see
all compaction activity without knowing each private receipt store.

Suggested API:

```ruby
store.compaction_activity(store: nil)
```

or:

```ruby
store.compaction_events(store: nil)
```

Return normalized entries from available sources:

```text
:__compaction_receipts
:__fact_prune_receipts
backend purge_receipts, when backend responds
```

Boundary-specific receipts can remain proof-local for now, but
`AvailabilityBoundaryLedger` may expose its own normalized helper if useful:

```ruby
ledger.compaction_activity
```

Suggested normalized entry:

```ruby
{
  kind: :retention_compaction | :exact_prune | :segment_purge | :boundary_physical_purge,
  executor: :store_compact | :fact_prune | :segmented_backend | :boundary_ledger,
  store: :orders,
  status: :ok,
  reason: :rolling_window,
  fact_count: 12,
  receipt_id: "...",
  occurred_at: ...
}
```

Do not expose full pruned fact payloads.

## Scope C: Naming / Docs Guardrails

Update package docs/comments so future slices do not introduce competing terms.

Minimum docs to update:

- `docs/progress.md`
- `docs/intelligent-ledger/ledger-boundaries-compaction-plan.md`
- this track handoff

Clarify:

```text
compact = lifecycle/intention
prune   = exact fact-id removal
purge   = physical storage artifact removal
```

## Scope D: Boundary Integration Check

`AvailabilityBoundaryLedger#purge_cleanup_execution` already uses
`prune_fact_ids`.

Add a focused integration check that the boundary physical purge receipt and
Store prune receipt both show up in the normalized activity/read model without
requiring callers to scan internal stores manually.

Keep this proof-local and additive.

## Acceptance

- Full package test suite passes.
- Existing compaction, prune, file backend, segmented backend, and intelligent
  ledger specs remain green.
- Add a failing-first or explicit spec showing whether current retention compact
  resurrects facts with FileBackend; final behavior prevents resurrection.
- `IgniterStore#compact` does not use unsafe `write_snapshot` as a physical
  deletion barrier.
- Retention compaction on FileBackend survives close/reopen.
- Retention compaction on in-memory store still works.
- Retention compaction with unsupported exact-prune backend is explicit, not
  silent.
- `SegmentedFileBackend#purge!` remains available as segment-level purge; no
  exact segment rewrite is attempted.
- A normalized compaction activity/read model exists and includes retention
  compaction + exact prune activity.
- If feasible, normalized activity also includes segmented purge receipts when
  backend supports `purge_receipts`.
- Boundary physical purge can be observed through the normalized activity/read
  model or a proof-local bridge.
- Docs clearly define compact/prune/purge and state that they are one lifecycle
  with multiple executors.
- Track handoff is appended at the end of this file.

## Non-Goals

- Do not add Ledger Open Protocol / HTTP / MCP endpoints yet.
- Do not implement exact per-fact rewrite of segmented WAL files.
- Do not rename every existing method in this slice.
- Do not move intelligent-ledger boundary proof into core API.
- Do not store full pruned payloads in activity entries.

## Risks / Watch Points

- Avoid double-writing confusing receipts. If both compaction receipt and prune
  receipt are needed, make their relationship explicit with ids/metadata.
- `compact` must not claim success when the backend cannot durably enforce the
  result.
- Segment purge is coarser than fact prune. The shared lifecycle should expose
  this difference, not hide it.
- Keep normal checkpoint non-destructive.

## Handoff

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/compaction-lifecycle-unification-v0
Status: done

[D] Decisions:
- Vocabulary is now canonical: compact = semantic/lifecycle, prune = exact fact-id
  executor, purge = physical storage artifact executor. Documented in progress.md and
  ledger-boundaries-compaction-plan.md; no new deletion API should bypass these terms.
- Scope A fix: replaced `@backend.write_snapshot` in `compact_store` with
  `@backend.replace_with_snapshot!` when the backend supports it.  This closes the
  same resurrection gap that the physical purge barrier track identified.
  Falls back to `write_snapshot` (non-destructive) when `replace_with_snapshot!` is
  absent, and skips entirely for in-memory stores.
- `durable: true/false` added to `compact` return shape.  `true` means the prune
  barrier was applied and compacted facts will not return on reopen.  `false` means
  the compaction is in-memory only (SegmentedFileBackend, no backend, or no drop).
- `durable: false` is NOT a failure — it is the explicit signal the track asked for.
  Callers must not treat it as an error; it simply means the backend does not
  guarantee resurrection-free reopen for retention-compacted facts.
- SegmentedFileBackend: does not implement `replace_with_snapshot!`; `compact` returns
  `durable: false`.  Segment-level physical deletion remains via `SegmentedFileBackend#purge!`.
- Scope B: `store.compaction_activity(store: nil)` normalizes entries from three
  sources: `:__compaction_receipts` (retention compaction), `:__fact_prune_receipts`
  (exact prune), and `backend.purge_receipts` (segment purge).  Entries have a
  stable shape: `{ kind:, executor:, store:, status:, reason:, fact_count:, receipt_id:, occurred_at: }`.
- Scope D: `ledger.compaction_activity` delegates to `store.compaction_activity` and
  appends boundary physical purge entries from `:ledger_physical_purge_receipts`.
  This is the single surface that operators need to observe the full lifecycle.

[S] Shipped:
- `IgniterStore#compact_store`: uses `replace_with_snapshot!` barrier when backend
  supports it; adds `durable:` to return hash.
- `IgniterStore#compaction_activity(store: nil)`: normalized activity read model
  spanning retention compaction, exact prune, and backend segment purge.
- `AvailabilityBoundaryLedger#compaction_activity`: full ledger activity including
  boundary physical purge receipts, sorted by `occurred_at`.
- `docs/progress.md`: canonical compaction vocabulary section added; test signal updated.
- `docs/intelligent-ledger/ledger-boundaries-compaction-plan.md`: compact/prune/purge
  vocabulary block added at the top.

[T] Tests:
- `spec/igniter/store/compaction_durability_spec.rb` (12 examples):
  Historical resurrection bug documented (write_snapshot leaves WAL intact);
  FileBackend compact → no resurrection; receipt survives reopen; facts written after
  compact survive reopen; in-memory store works; SegmentedFileBackend returns
  `durable: false`; no-drop returns `durable: false`.
- `spec/igniter/store/compaction_activity_spec.rb` (23 examples):
  Retention compaction entries, filter by store, empty when no compact;
  Exact prune entries; Segment purge entries (real SegmentedFileBackend scenario);
  Ordering; Boundary integration (all 5 ledger activity checks).
- Full suite: 1132 examples, 0 failures (native extension active).

[R] Risks / next recommendations:
- Native mode snapshot round-trip converts Ruby Symbol values (e.g. `:things`) to
  bare strings after write_snapshot → load_native_snapshot → Fact.build.  This is the
  known Phase 2 gap (Fact.build regenerates id/timestamp).  Specs normalize with
  `.to_sym` where needed.  This does NOT affect correctness of the barrier or read
  model, only the specific symbol type assertion.
- `compact_store` still writes a compaction receipt AND the prune barrier applies.
  There is no separate prune receipt for retention compaction — this avoids double
  receipts.  `compaction_activity` sees only the compaction receipt for these events.
  If `fact_ids` of compacted facts are needed in the activity, callers should use
  `compaction_receipts` directly (which records oldest/newest dropped IDs).
- `SegmentedFileBackend#purge!` segment receipts use the `"fact_count"` key from the
  manifest (which reflects the sealed count at checkpoint time).  If segments are
  appended across multiple checkpoints, the count in the purge receipt matches the
  sealed segment, not the total store count.
- Next natural slice: expose `compaction_activity` via the Open Protocol / wire
  transport so remote-backed stores and LedgerServer can surface compaction history
  without direct Ruby access.
```
