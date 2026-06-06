# Track: Contractable Observation Receipts v0

Status date: 2026-05-04
Status: ready
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Strengthen `igniter-embed` contractable shadowing as the Spark CRM migration
bridge.

Spark pressure says the first safe production path is not to replace a Rails
service. It is:

```text
legacy primary service
  -> unchanged production result
  -> optional candidate/shadow execution
  -> normalized observation
  -> durable observation receipt
  -> durable divergence/acceptance/store-error receipts
  -> redacted payloads only
```

This slice should keep `igniter-embed` Rails-free, but make the contractable
observation output strong enough for a Rails/Sidekiq host such as Spark CRM to
persist receipts and link them from logs/admin screens.

## Read First

Use the compact fresh-chat route:

1. `packages/igniter-embed/README.md`
2. `playgrounds/docs/dev/tracks/differential-shadow-contractable-track.md`
3. `packages/igniter-embed/lib/igniter/embed/contractable/config.rb`
4. `packages/igniter-embed/lib/igniter/embed/contractable/runner.rb`
5. `packages/igniter-embed/spec/igniter/embed/contractable_spec.rb`
6. SparkCRM companion proposal context, if explicitly available in the
   consuming workspace
7. this track

Then inspect only the files needed for this track.

## Relationship To Legacy Track

This is not a reimplementation of the old differential shadow contractable
track.

The archived track already landed the baseline:

```text
contractable runner
  -> primary synchronous result
  -> candidate shadow path
  -> DifferentialPack comparison
  -> acceptance policies :exact / :completed / :shape
  -> observed-service mode
  -> role/stage metadata
  -> store.record(observation)
  -> async true uses a local non-durable thread adapter by default
```

This slice is Phase 2:

```text
existing observation hash
  -> stable observation identity
  -> canonical receipt fields
  -> compact event receipts
  -> richer optional store adapter hooks
  -> redaction policy metadata
  -> async handoff descriptor
```

Do not redo the runner semantics from the archived track unless tests prove
they are broken.

## Spark Pressure

The first concrete Spark target is:

```text
Api::Marketing::ExecutorService
```

Spark needs to wrap it in observation/shadow mode:

```text
primary: current Rails executor
candidate: no-op mirror or future Igniter contract
normalizer: production response shape
redaction: provider payload and technician/customer data policy
store: durable receipt sink
events: divergence, primary error, candidate error, acceptance failure, store error
```

No production response change.

## Current Baseline

`Contractable::Runner` already produces an observation hash and calls:

```text
store_adapter.record(observation)
on_observation callback
typed event handlers
```

Current gaps:

- no stable `observation_id`
- no canonical receipt shape
- divergence is an event callback, not a durable receipt payload
- store adapter protocol only has `record(observation)`
- redaction is input-only; output/metadata/error redaction is not explicit
- sampling has no durable unsampled receipt option beyond a normal observation
- async adapter shape exists, but there is no explicit job descriptor for
  Rails/Sidekiq-style durable async handoff

## Scope A: Canonical Observation Receipt Shape

Add a small value object or plain helper for canonical contractable receipts.

Suggested shape:

```ruby
{
  schema_version: 1,
  receipt_kind: :contractable_observation,
  observation_id: "obs_...",
  name: :lead_decision,
  role: :migration_candidate,
  stage: :shadowed,
  mode: :shadow,
  sampled: true,
  async: false,
  status: :ok,
  started_at: "...",
  finished_at: "...",
  duration_ms: 12.4,
  inputs: { ...redacted... },
  primary: { status:, outputs:, metadata:, error: },
  candidate: { status:, outputs:, metadata:, error: },
  report: { match:, summary:, details: },
  match: false,
  accepted: false,
  acceptance: { ... },
  metadata: { ... },
  redaction: { policy: ..., classes: [...] }
}
```

Keep the existing observation hash compatible, but add stable receipt fields.
If a value object is overkill, a private helper in `Runner` is acceptable for
this slice.

Required:

- `observation_id` is generated once per primary call.
- `receipt_kind` and `schema_version` are present.
- `status` summarizes the observation:
  - `:ok`
  - `:diverged`
  - `:candidate_error`
  - `:acceptance_failed`
  - `:store_error`
  - `:unsampled`
- existing specs still pass or are updated intentionally.

## Scope B: Durable Event Receipts

For typed events, include a compact event receipt payload:

```ruby
{
  schema_version: 1,
  receipt_kind: :contractable_event,
  event_id: "evt_...",
  observation_id: "obs_...",
  event: :divergence,
  name: :lead_decision,
  occurred_at: "...",
  severity: :info | :warning | :error,
  summary: "...",
  observation_ref: {
    observation_id: "obs_...",
    match: false,
    accepted: false
  },
  metadata: { ...redacted... }
}
```

Attach this event receipt to the event payload sent to handlers:

```ruby
event_payload[:receipt]
```

Required events:

- `:divergence`
- `:primary_error`
- `:candidate_error`
- `:acceptance_failure`
- `:store_error`
- `:observation`

Do not persist event receipts automatically unless the configured store adapter
supports it.

## Scope C: Store Adapter Protocol Upgrade

Preserve current adapter compatibility:

```ruby
store.record(observation)
```

Add optional richer hooks:

```ruby
store.record_observation(receipt)
store.record_event(receipt)
```

Rules:

- If `record_observation` exists, call it with the canonical observation receipt.
- Else fall back to `record(observation)` for compatibility.
- If `record_event` exists, call it for event receipts after observation
  recording.
- Store errors must not change the primary result.
- Store errors should produce `:store_error` event receipt.

This gives Rails/Spark a clean adapter point for:

```text
ActiveRecord table
Sidekiq outbox
Igniter Store
JSONL/file
```

without adding Rails as a dependency.

## Scope D: Redaction Policy Metadata

Keep redaction simple but explicit.

Existing:

```ruby
config.redact_inputs ->(**inputs) { ... }
use :redaction, only: [...]
use :redaction, except: [...]
```

Add metadata to receipts that describes the policy without exposing raw values:

```ruby
redaction: {
  input_policy: :custom | :only | :except | :none,
  output_policy: :none,
  classes: []
}
```

Do not implement deep output redaction unless it is small and natural. The main
requirement is that receipts say what redaction policy was applied.

## Scope E: Async Handoff Descriptor

When async candidate work is enqueued, include a compact descriptor:

```ruby
{
  schema_version: 1,
  kind: :contractable_async_handoff,
  observation_id: "obs_...",
  name: :lead_decision,
  inputs: { ...redacted... },
  metadata: { ... },
  queued_at: "..."
}
```

Pass it to async adapters if possible without breaking existing adapters.

Suggested compatibility path:

```ruby
enqueue(name:, inputs:, metadata:, handoff: nil, &block)
```

If an adapter does not accept `handoff:`, fall back to the existing call shape.

This is not a durable job queue implementation. It only makes Sidekiq/ActiveJob
adapters easier to write correctly.

## Acceptance

- Full `packages/igniter-embed` test suite passes.
- Existing contractable behavior remains compatible:
  - primary result returned synchronously
  - no-store mode works
  - async default/local adapter works
  - old `store.record(observation)` adapters still work
- Observation includes `schema_version`, `receipt_kind`, and stable
  `observation_id`.
- Observation `status` is covered for match, divergence, candidate error,
  acceptance failure, store error, and unsampled paths.
- Event payloads include `:receipt` with event_id, observation_id, event,
  severity, summary, and observation_ref.
- `record_observation` is preferred when present.
- `record_event` is called when present and does not replace normal event
  handlers.
- Store failures still do not alter the primary result.
- Redaction metadata is present in receipts.
- Async adapter can receive a handoff descriptor while old adapters continue to
  work.
- README is updated with a compact Spark-style example showing observation
  receipt and divergence receipt.
- Track handoff is appended at the end of this file.

## Non-Goals

- Do not add Rails, ActiveJob, Sidekiq, ActiveRecord, or igniter-ledger as hard
  dependencies.
- Do not implement the Spark companion app in this slice.
- Do not build a web receipt viewer yet.
- Do not promote candidate output to production authority.
- Do not implement full PII classification.

## Risks / Watch Points

- Keep primary call path stable. Observation failures must never change the
  returned primary result.
- Be careful with async signature compatibility. Old adapters in tests should
  not break.
- Do not store raw inputs in receipts unless redaction explicitly allows them.
- Avoid making receipts too large; report details are useful, but event receipts
  should be compact refs.

## Handoff Template

```text
[Package Agent / Companion+Store]
Track: igniter-embed/contractable-observation-receipts-v0
Status: done | partial | blocked

[D] Decisions:
- ...

[S] Shipped:
- ...

[T] Tests:
- ...

[R] Risks / next recommendations:
- ...
```

---

## Handoff

```text
[Package Agent / Companion+Store]
Track: igniter-embed/contractable-observation-receipts-v0
Status: done

[D] Decisions:
- observation_id generated once per call() invocation, threaded through all
  downstream helpers as a keyword parameter (not stored as instance variable —
  Runner instances are reused across concurrent calls).
- status computed in record_observation after the store attempt so it can
  reflect :store_error correctly; set as nil in observation() and filled in
  immediately after the store call.
- Priority order for status: unsampled > store_error > candidate_error >
  acceptance_failed > diverged > ok. Matches the "root cause first" principle.
- record_event called inside dispatch_event for all events (including
  primary_success). Store implementations that only want significant events
  should filter by severity or event type.
- dispatch_async uses Method#parameters introspection to detect handoff:
  support — avoids rescue ArgumentError and is safe for frozen objects.
- redaction_input_policy tracked on Config, defaulting to :custom. SugarBuilder
  sets :only or :except when use :redaction is called with those options.
- Built-in adapters (InlineAsync, ThreadAsync) updated to accept handoff: nil.

[S] Shipped:
- runner.rb: observation_id, receipt_kind, schema_version, status, redaction
  metadata in every observation hash (Scope A).
- runner.rb: build_event_receipt generates event_id, severity, summary,
  observation_ref; attached as :receipt in every event payload (Scope B).
- runner.rb: record_observation now prefers store.record_observation(receipt)
  over store.record(observation); dispatch_event calls store.record_event(receipt)
  when present; store errors still do not alter primary result (Scope C).
- config.rb + sugar_builder.rb: redaction_input_policy tracked and reflected
  in observation[:redaction] (Scope D).
- runner.rb: build_async_handoff descriptor passed via dispatch_async with
  Method#parameters compat check; adapters.rb updated with handoff: nil (Scope E).
- README.md: Spark-style example with SparkObservationStore, SidekiqObservationAdapter,
  divergence event receipt shape, and status vocabulary.

[T] Tests:
- Full suite: 77 examples, 0 failures.
- New contractable_spec.rb tests cover: observation_id format, uniqueness,
  all 6 status values, event receipt fields (event_id, severity, summary,
  observation_ref), observation_id linking, record_observation preference,
  record_event called per event, handlers still fire when record_event present,
  legacy record() fallback, store failure isolation, redaction policy metadata
  (:custom/:only/:except), handoff descriptor in queue, legacy adapter compat.

[R] Risks / next recommendations:
- record_event is called for primary_success (pre-observation). Stores that
  only want post-observation events should filter by event type. Could be
  narrowed to observation-phase events only if noise becomes a concern.
- Async handoff is a descriptor only — no durable job is created. Spark must
  implement the SidekiqObservationAdapter or similar to make async work
  durable. The descriptor provides everything needed (observation_id, name,
  inputs, queued_at).
- output redaction is :none — receipts document this explicitly. Deep output
  PII redaction can be added in a future slice if Spark identifies specific
  fields that must not appear in stored observations.
```
