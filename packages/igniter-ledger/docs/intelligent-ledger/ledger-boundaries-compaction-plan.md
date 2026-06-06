# Ledger Boundaries / Timeframes Plan

Status date: 2026-05-04
Status: research horizon
Supervisor: [Architect Supervisor / Codex]

## Compaction Vocabulary (canonical — do not introduce competing terms)

```text
compact  — semantic verb: reduce retained detail while preserving truth/proof
prune    — exact fact-id executor: remove facts from the hot logical log
purge    — physical storage executor: remove whole storage artifacts (segments)
```

All three share one lifecycle, inspectable via `store.compaction_activity` /
`ledger.compaction_activity`.  Executors are specialized; vocabulary is unified.

## Insight

An intelligent ledger cannot keep every high-frequency operational fact forever
at full fidelity and also stay compact, fast, and cheap.

For domains like technician schedules, sensor streams, call state, delivery
attempts, and lead routing, raw facts can grow quickly. Replaying the full
history of a technician every time a new order arrives is the wrong mental
model.

The ledger needs a middle primitive:

```text
many fine-grained facts
  -> closed semantic container
  -> compact boundary receipt
  -> optional internal detail retention / purge
```

Canonical research name: `LedgerBoundary`.

Avoid using `Frame` as the primary public name because `igniter-ledger` already
uses frame terminology for low-level WAL and wire encoding. `Timeframe` can be
a specific boundary shape for time-bounded domains.

Avoid using `Capsule` because Igniter already has public Application Capsules
in the application/hub layer. Avoid using bare `Container` because Igniter has
embedded contract containers and app/UI code commonly uses container language.

Short DSL spelling can still be `boundary`.

## Core Model

A `LedgerBoundary` is a closed, inspectable semantic boundary over facts.

```text
LedgerBoundary
  id
  type
  subject
  window
  inputs
  outputs
  source_fact_refs
  internal_fact_refs
  result_hash
  rule_versions
  closed_at
  compaction_policy
  detail_status
```

The boundary says:

- these facts were considered together
- these were the external inputs
- this was the resulting output/snapshot/receipt
- these rules/versions produced the result
- the boundary is closed and will not be recomputed unless explicitly reopened
- internal facts may later be retained, downsampled, archived, encrypted, or
  purged without losing the boundary truth

## Why This Matters

Without boundaries:

```text
new schedule fact
  -> replay technician history forever
  -> recompute every intermediate state
  -> growing cost and noisy explanations
```

With boundaries:

```text
technician day boundary
  inputs: starting availability + day_off_config + orders + off_schedules
  outputs: closed availability snapshot + conflicts + receipts
  internals: detailed slot mutations

new next-day fact
  -> start from previous boundary output
  -> use only relevant open boundary facts
```

This gives the ledger an event-sourcing-like snapshot boundary, but with
business meaning and receipts instead of only technical snapshots.

## Boundary Types

### Timeframe Boundary

Good for schedules, availability, sensor windows, hourly lead load, daily
technician state.

```text
AvailabilityDayBoundary(company_id, technician_id, date)
  window: 2026-05-04 00:00..23:59
  input: previous day carryover, day_off_config, schedules, off_schedules
  output: slot availability snapshot, conflict list, capacity metrics
```

### Decision Boundary

Good for lead decisions and support explanations.

```text
LeadDecisionBoundary(provider, request_id)
  input: raw request, normalized request, company config, availability snapshot
  output: accept/reject/bid/DID/reason
  internal: validation and scoring step facts
```

### Correlation Boundary

Good for telephony/order/vendor matching.

```text
CallCorrelationBoundary(call_id)
  input: CallRail facts, RingCentral facts, Ringba win facts, order candidates
  output: selected links, rejected candidates, confidence
```

### Delivery Boundary

Good for notifications and provider fan-out.

```text
NotificationDeliveryBoundary(notification_id)
  input: recipients, channels, provider attempts
  output: final delivered/failed/fallback state
```

## Open vs. Closed

Boundaries have lifecycle:

```text
open
  -> accepts internal facts
  -> may update derived snapshot

closing
  -> final derivation runs
  -> output receipt written

closed
  -> immutable boundary
  -> can be used as a compact input for future derivations

compacted
  -> internal details reduced or removed
  -> boundary receipt remains
```

Important rule:

```text
closed boundary output is a valid input fact
```

This is the "matryoshka" property: a larger derivation can use boundary outputs
without needing to open every smaller boundary inside it.

## Replay Semantics

The ledger should distinguish three replay levels:

```text
full replay
  uses all internal facts and receipts

boundary replay
  uses boundary input/output receipts only

summary replay
  uses compact boundary outputs and aggregate hashes
```

After compaction, full replay may no longer be possible locally, but boundary
replay must remain correct.

This makes compaction honest:

- do not pretend detailed history exists after purge
- preserve enough boundary proof to explain outputs
- expose `detail_status: :full | :summarized | :archived | :purged`

## Relationship To Existing Concepts

`RetentionPolicy`
  currently drops/keeps facts and writes compaction receipts.

`LedgerBoundary`
  gives retention a semantic boundary so compaction can preserve business
  truth, not only technical counts.

`AvailabilitySnapshot`
  is a natural boundary output.

`Receipt`
  is the public proof of boundary closure.

`Changefeed`
  can emit boundary lifecycle events instead of every internal fact to low-detail
  subscribers.

`SyncProfile`
  can ship full boundaries to dev/cold storage and compact boundaries to
  production/hot stores.

## Contract-Level DSL Sketch

Boundaries should be declared at the contract/capability layer, not as ad-hoc
storage rules.

Example:

```ruby
contract :ScheduleFact do
  history key: :id, adapter: :ledger

  field :id
  field :company_id
  field :technician_id
  field :order_id
  field :status
  field :starts_at
  field :ends_at

  boundary :technician_day,
          subject: %i[company_id technician_id],
          window: { by: :starts_at, bucket: :day } do
    include_facts :schedule_created, :schedule_moved, :schedule_cancelled
    include_facts :off_schedule_created, :day_off_config_changed

    input :previous_day_output, from: :previous_boundary
    output :availability_snapshot
    output :conflicts
    output :capacity_metrics

    close when_time_passed: :window_end
    compact internals: :after_close, keep: :boundary
  end

  boundary :order_lifecycle,
          subject: %i[company_id order_id],
          close: { when_status: :completed } do
    include_facts :schedule_created, :schedule_status_changed
    output :order_schedule_summary
    compact internals: :after_close, keep: :summary
  end
end
```

The key idea:

```text
store declares fact shape
boundary declares semantic grouping / closure / compaction
```

The boundary is not the store. It is an additional boundary over facts.

## Boundary Closure Triggers

Boundaries should support several closure modes:

```ruby
close after: 1.day
close every: 1.hour
close when_count: 1_000
close when_bytes: 64.megabytes
close when_status: :completed
close when_event: :order_cancelled
close when_rule: :no_open_slots
close manually: true
```

Suggested categories:

| Trigger | Use case |
|---------|----------|
| time window | daily availability, hourly lead load, sensor buckets |
| count | high-volume append streams |
| byte size | storage safety / segment rollover |
| status/event | order completed, notification finalized, call ended |
| rule | capacity exhausted, route reached terminal state |
| explicit command | settlement, operator close, maintenance job |

Multiple triggers can coexist. The first terminal trigger closes the boundary and
records why:

```ruby
closed_by: { kind: :time_window, rule: :window_end, observed_at: ... }
```

## Multiple Boundaries Per Store

Multiple boundary policies per store are valid and desirable.

Example:

```text
store: :schedule_facts

boundary policy: :technician_day
  subject: company_id + technician_id + date
  output: availability snapshot

boundary policy: :order_lifecycle
  subject: company_id + order_id
  output: schedule/order summary

boundary policy: :company_capacity_hour
  subject: company_id + hour
  output: aggregate capacity metrics
```

A single fact can belong to several boundaries:

```text
ScheduleCreated(order_id=9, technician_id=7, starts_at=2026-05-04 10:00)
  -> technician_day(company=1, technician=7, date=2026-05-04)
  -> order_lifecycle(company=1, order=9)
  -> company_capacity_hour(company=1, hour=2026-05-04 10:00)
```

This is not a contradiction because boundaries are named semantic projections,
not competing canonical stores.

Contradiction exists only when two boundaries claim the same identity:

```text
same policy_name
same subject
same window
same rule_version
different closed output hash
```

That should produce a conflict/correction receipt, not overwrite either result.

Boundary identity should be deterministic:

```text
boundary_key = hash(policy_name + subject + window + rule_version)
```

Late facts for a closed boundary should create one of:

- a correction boundary
- a superseding boundary
- a late-fact receipt attached to the original boundary

The original closed boundary remains immutable.

## Physical Layout Hypothesis

Do not make "fact file" and "boundary file" two competing sources of truth.

Preferred physical planes:

```text
wal/
  store=schedule_facts/
    date=2026-05-04/
      segment-000001.wal

boundaries/
  policy=technician_day/
    store=schedule_facts/
      date=2026-05-04/
        boundary-<boundary_key>.json
        internals-<boundary_key>.wal        # optional, only for boundary-owned detail

  policy=order_lifecycle/
    store=schedule_facts/
      company=1/
        boundary-<boundary_key>.json

receipts/
  boundary_closure/
  boundary_compaction/
```

The primary fact WAL remains append-only truth. Boundary files are semantic
indexes / manifests / boundary receipts over that truth.

Boundary storage can have modes:

### Reference-Only Boundary

Boundary stores fact references, source ranges, input/output hashes, and result.
Raw facts remain in normal WAL segments.

Use when detail replay is needed while raw retention remains hot/warm.

### Boundary-Owned Detail

Boundary has an internal detail WAL/segment for facts that are only meaningful
inside the boundary. Boundary facts and receipts still go to normal WAL.

Use when high-volume details should be physically compacted or archived per
boundary.

### Boundary-Only Boundary

After compaction, boundary keeps only inputs, outputs, hashes, counts, and
receipt links. Internal facts may be purged, archived, or shipped to cold
storage.

Use for production hot stores that need correct current/replay behavior without
full forensic detail.

## Query / Replay Implication

Replay should choose the cheapest valid source:

```text
query availability for technician day
  if open boundary exists:
    use previous closed boundary output + open facts

  if closed boundary exists and boundary fidelity is enough:
    use boundary output directly

  if full detail required and detail_status == :full:
    replay internal facts

  if full detail required and detail_status != :full:
    return detail_unavailable with boundary receipt
```

This avoids full-history replay while keeping honesty about lost detail.

## Pre-Compaction Settlement

Before a boundary loses internal detail, it should have a chance to materialize
the useful memory hidden inside those details.

Compaction should not mean:

```text
delete internals
```

It should mean:

```text
settle boundary
  -> run declared pre-compaction transforms
  -> persist outputs / metrics / reports / approximations
  -> write settlement receipt
  -> only then compact or purge internal detail
```

Working lifecycle:

```text
open
  -> closed
     -> settling
        -> settled
           -> compacted
```

The `settled` state says: "all required memory-preserving transforms have
successfully run; it is now safe to reduce detail according to policy."

## Pre-Compaction Transform Types

Boundaries should support declarative transform hooks before internal facts are
summarized or purged.

### Approximation / Signal Processing

Good for high-frequency geo and sensor facts.

```text
raw GPS pings
  -> Kalman-smoothed path
  -> route segments
  -> stop/start intervals
  -> distance/time metrics
  -> purge noisy raw points
```

Possible outputs:

- smoothed polyline
- bounding boxes
- visit intervals
- distance travelled
- confidence/error metrics

### Business Summaries

Good for order/schedule/operation domains.

```text
order schedule mutations
  -> final order schedule summary
  -> conflict report
  -> technician utilization summary
  -> customer contact timeline
```

Possible outputs:

- `OrderLifecycleSummary`
- `TechnicianDaySummary`
- `ScheduleConflictReport`
- `NotificationDeliverySummary`

### Metrics / Statistics / Analytics

Good for dashboards and long-range retention.

```text
lead decisions for one hour
  -> accepted_count
  -> rejected_count by reason
  -> avg bid
  -> no-capacity rate
  -> top ZIPs
```

Possible outputs:

- counters
- histograms
- percentiles
- min/max/avg
- rollup facts for reports

### Proof / Audit Summaries

Good for support and compliance.

```text
internal decision steps
  -> input digest
  -> rule versions
  -> source ref ranges
  -> output hash
  -> redacted explanation
```

Possible outputs:

- support-safe receipt
- redacted error report
- rule-version manifest
- source range proof

## DSL Sketch For Settlement

```ruby
boundary :technician_geo_day,
         subject: %i[company_id technician_id],
         window: { by: :observed_at, bucket: :day } do
  include_facts :geo_ping

  before_compact do
    transform :kalman_path, output: :smoothed_route
    summarize :stops, output: :visit_intervals
    metric :distance_miles
    metric :drive_time_minutes
  end

  compact internals: :after_settlement, keep: :boundary
end
```

Business example:

```ruby
boundary :technician_day,
         subject: %i[company_id technician_id],
         window: { by: :starts_at, bucket: :day } do
  include_facts :schedule_created, :schedule_moved, :off_schedule_created

  before_compact do
    summarize :availability, output: :availability_snapshot
    report :conflicts, output: :schedule_conflict_report
    metric :capacity_percent
    metric :completed_jobs_count
  end

  compact internals: :after_settlement, keep: :boundary
end
```

The names above are research sketches, not public API.

## Settlement Rules

- Required settlement transforms must succeed before detail is purged.
- Optional transforms may fail and produce warning receipts if policy allows it.
- Every transform output must be content-addressed or have a stable result hash.
- Every transform must record:
  - transform name
  - transform version
  - input fact refs or source ranges
  - output fact refs
  - result hash
  - error/warning state if applicable
- Settlement itself writes a receipt.
- Cleanup eligibility depends on settlement status, not only closure status.

Updated cleanup rule:

```text
fact is purge-eligible when:
  retention policy allows purge
  AND all required boundary policies for that fact are closed
  AND all required settlement transforms are settled
  AND every closed boundary has durable boundary output + receipt
  AND every boundary either:
        keeps no-detail boundary replay
        OR archived its internals elsewhere
        OR explicitly allows internal purge
  AND no open sync/export/diagnostic cursor requires the raw fact
```

## Fact Cleanup Eligibility

Raw fact cleanup needs more than a retention timer.

Facts can be physically purged only when all semantic consumers that need them
have reached a safe boundary.

Suggested rule:

```text
fact is purge-eligible when:
  retention policy allows purge
  AND all required boundary policies for that fact are closed
  AND all required settlement transforms are settled
  AND every closed boundary has durable boundary output + receipt
  AND every boundary either:
        keeps no-detail boundary replay
        OR archived its internals elsewhere
        OR explicitly allows internal purge
  AND no open sync/export/diagnostic cursor requires the raw fact
```

This turns cleanup into a permissioned operation, not a blind deletion.

The ledger should be able to answer:

```text
Can I purge facts before 2026-01-01 for store=schedule_facts?

No:
  technician_day(company=1, technician=7, date=2025-12-31) is still open
  sync cursor "analytics-hub" has not ACKed segment 2025-12-31/000042

Yes:
  all required boundaries closed
  boundary receipts retained
  internals archived to cold store
```

## Required vs. Optional Boundary Policies

Not every boundary should block raw cleanup.

Example:

```text
required:
  technician_day
  order_lifecycle

optional:
  company_capacity_hour
  debug_trace_boundary
```

Cleanup rule:

- required boundary policies must close or explicitly release the fact
- optional boundary policies may be skipped after their own retention window
- debug/diagnostic boundaries should not block production cleanup forever

DSL sketch:

```ruby
boundary :technician_day, required_for_purge: true do
  # ...
end

boundary :debug_trace, required_for_purge: false do
  compact internals: :after, duration: 7.days, keep: :none
end
```

## Meta-Boundaries And Alignment

Large retention boundaries need larger boundaries over smaller boundaries.

Example:

```text
TechnicianDayBoundary
  -> TechnicianMonthBoundary
     -> TechnicianYearBoundary
        -> CompanyYearArchiveBoundary
```

This gives an alignment point for old data:

```text
new year starts
  -> close all 2025 day/month/year boundaries
  -> write CompanyYearArchiveBoundary(2025)
  -> archive or purge raw 2025 internals
  -> keep annual boundary output + receipts hot
```

Meta-boundaries should consume boundary outputs, not reopen all internal facts by
default:

```text
day outputs
  -> month output
  -> year output
  -> archive manifest
```

This is the larger "matryoshka" layer. A year boundary can remain useful even
after day-level internals are gone, because it has durable inputs/outputs and
proof hashes.

## Cleanup Plan Shape

Cleanup should first produce a plan, then execute.

```ruby
plan = ledger.cleanup_plan(
  store: :schedule_facts,
  before: Time.utc(2026, 1, 1),
  fidelity: :boundary
)
```

Plan shape:

```ruby
{
  status: :ready, # or :blocked
  store: :schedule_facts,
  before: "2026-01-01T00:00:00Z",
  purge_candidate_count: 1_240_000,
  blocking_boundaries: [],
  blocking_cursors: [],
  required_boundary_policies: %i[technician_day order_lifecycle],
  receipts_to_keep: [...],
  archive_target: :cold_store,
  expected_detail_status: :archived
}
```

Execution must emit a cleanup receipt:

```text
FactCleanupReceipt
  store
  before
  fact_count
  byte_count
  boundary_policy_refs
  boundary_output_refs
  archive_ref
  detail_status_after
  executed_at
```

Cleanup must be idempotent. Re-running the same cleanup should return the same
receipt or a deduplicated receipt, not delete additional data silently.

## Late Facts After Cleanup

Late facts can arrive after a timeframe is closed and raw internals are purged.

Possible policies:

```text
reject
  refuse late fact because the boundary/archive is sealed

correction
  write late fact as a correction boundary against the old boundary

supersede
  create a new superseding boundary output and mark old boundary superseded

append_to_next
  attach the fact to the current open boundary when business semantics allow it
```

The default should be `correction`, not mutation.

The original closed boundary remains immutable.

## Cross-Store Reference Consistency

Boundaries must preserve reference consistency when raw facts are compacted.

Problem:

```text
OrderAssignedFact
  id: fact-123
  store: :order_events

NotificationFact
  references: fact-123

later:
  fact-123 is compacted/purged inside TechnicianDayBoundary
```

The reference from `NotificationFact` must not become silently broken.

Target behavior:

```text
resolve(fact-123)
  -> raw fact exists
     return direct fact

  -> raw fact compacted
     return boundary redirect / proof reference

  -> raw fact unknown
     return not_found
```

This creates a "redirect" layer from raw fact IDs to boundary evidence.

## Boundary Redirect Reference

When a boundary compacts internal facts, it should preserve a compact reference
map for purged internal fact IDs.

Suggested shape:

```text
FactRedirect
  original_fact_id
  original_store
  boundary_key
  boundary_policy
  boundary_output_fact_id
  boundary_receipt_id
  settlement_receipt_id
  detail_status
  reference_role
  compacted_at
```

`reference_role` explains what kind of evidence remains:

```text
:included_in_boundary
:summarized_by_boundary
:aggregated_into_metric
:redacted_in_boundary
:archived_elsewhere
```

Example:

```text
fact order_event:fact-123
  -> compacted by technician_day/company=1/technician=7/date=2026-05-04
  -> redirect says:
       "fact-123 is no longer hot, but it was included in this closed boundary,
        whose output hash and settlement receipt are retained."
```

## Reference Resolution Modes

Callers should be explicit about required reference fidelity.

```ruby
ledger.resolve_ref("fact-123", fidelity: :raw)
ledger.resolve_ref("fact-123", fidelity: :boundary)
ledger.resolve_ref("fact-123", fidelity: :summary)
```

Possible outcomes:

```ruby
{ status: :ok, kind: :raw_fact, fact: ... }

{ status: :redirected,
  kind: :boundary_ref,
  original_fact_id: "fact-123",
  boundary_key: "...",
  detail_status: :purged,
  evidence: {
    boundary_output_fact_id: "...",
    boundary_receipt_id: "...",
    settlement_receipt_id: "..."
  }
}

{ status: :detail_unavailable,
  original_fact_id: "fact-123",
  boundary_key: "...",
  required_fidelity: :raw,
  available_fidelity: :boundary
}

{ status: :not_found, original_fact_id: "fact-123" }
```

This prevents silent downgrade:

- `fidelity: :raw` fails if the raw fact was purged.
- `fidelity: :boundary` may follow redirects.
- `fidelity: :summary` may accept settlement metrics/reports only.

## Cross-Store Relation Projection

Cross-store relations should not point only to raw fact IDs.

They should be able to resolve through a reference chain:

```text
Order
  -> ScheduleFact raw ref
     OR BoundaryRedirect ref
        -> TechnicianDayBoundary
        -> AvailabilitySummary / SettlementReceipt
```

Relation index entries should include enough metadata to survive compaction:

```text
RelationEdge
  from_store
  from_key
  to_store
  to_key
  to_fact_id
  to_boundary_key
  ref_status: :raw | :redirected | :unresolved
  fidelity: :raw | :boundary | :summary
```

When raw detail is compacted:

```text
relation edge
  :raw -> :redirected
```

not:

```text
relation edge disappears
```

## Boundary Compaction Reference Rule

Before purging internal facts, compaction must ensure one of:

```text
1. no external references exist for the internal facts
2. all external references have redirect entries
3. referenced facts are archived and redirect entries point to archive refs
```

Cleanup eligibility therefore expands again:

```text
fact is purge-eligible when:
  retention policy allows purge
  AND all required boundary policies for that fact are closed
  AND all required settlement transforms are settled
  AND external references are either absent or redirected
  AND every closed boundary has durable boundary output + receipt
  AND every boundary either:
        keeps no-detail boundary replay
        OR archived its internals elsewhere
        OR explicitly allows internal purge
  AND no open sync/export/diagnostic cursor requires the raw fact
```

This keeps the ledger referentially honest after compaction.

## Aggregation Consistency With Boundaries

Aggregations must declare which fidelity they require.

```text
raw aggregation
  reads raw internal facts

boundary aggregation
  reads boundary outputs / settlement summaries / metrics

summary aggregation
  reads rollups or sketches only
```

Never silently mix raw facts and boundary summaries without reporting it.

Suggested result metadata:

```ruby
{
  value: 82.4,
  operation: :avg,
  fidelity: :boundary,
  source: :settlement_metrics,
  coverage: :complete,
  boundaries: [...],
  detail_status: :mixed
}
```

Algebra rule for settlement outputs:

```text
sum        -> preserve sum
count      -> preserve count
avg        -> preserve sum + count
min/max    -> preserve min/max
percentile -> preserve histogram/sketch, not only one percentile number
```

This lets larger boundaries and reports aggregate correctly over smaller
boundaries after raw detail is gone.

## Product Example: Technician Availability

```text
TechnicianAvailabilityDayBoundary
  subject:
    company_id: 42
    technician_id: 7
    date: 2026-05-04

  inputs:
    day_off_config_hash
    company_window_hash
    previous_boundary_output_id

  internal facts:
    schedule_created
    schedule_moved
    off_schedule_created
    order_cancelled
    slot_conflict_detected

  output:
    available_slots
    busy_slots
    off_slots
    conflict_count
    capacity_percent
    next_open_slot

  closure:
    closed_at: end_of_day or explicit settlement
    result_hash: sha256(output + source refs + rule versions)
```

When a future lead decision needs availability, it can reference:

```text
AvailabilitySnapshotCreated(boundary_id: ...)
```

not replay every schedule mutation from the beginning of time.

## Safety Rules

- A boundary can summarize facts, but must not silently rewrite history.
- If internal facts are purged, `detail_status` must say so.
- A compacted boundary must keep input/output hashes and source reference ranges.
- Reopening a closed boundary should create a correction boundary or superseding
  boundary, not mutate the original.
- Compaction must emit a receipt.
- Consumers must be able to choose required fidelity:
  - `require_detail: true`
  - `allow_boundary: true`
  - `allow_summary: true`

## Open Questions

- Should `LedgerBoundary` be core ledger vocabulary or an intelligent-ledger
  extension first?
- Is boundary closure automatic by time window, explicit by command, or both?
- Do boundary internals live in the same store, a child store, or segmented
  partitions?
- Should compacted internal facts be replaced by one synthetic summary fact or
  by boundary output only?
- How do we model late-arriving facts for an already closed timeframe?
- What is the minimal API:

```ruby
boundary :technician_day, subject: %i[company_id technician_id date] do
  window by: :date
  input :day_off_config
  include_facts :schedules, :off_schedules
  output :availability_snapshot
  compact internals: :after_close, keep: :boundary
end
```

## Suggested First Proof

Build a small in-memory proof, not package API:

```text
TechnicianAvailabilityDayBoundary
  -> append 5 schedule/off-schedule facts
  -> derive availability output
  -> close boundary
  -> compact internals
  -> prove boundary replay still returns the same availability output
  -> prove full replay reports detail unavailable after purge
```

Acceptance:

- no full-history replay needed after boundary closure
- output hash remains stable
- compaction receipt records what detail was removed
- late fact creates correction/superseding boundary instead of mutating closed one
- the model can feed a LeadDecisionReceipt
