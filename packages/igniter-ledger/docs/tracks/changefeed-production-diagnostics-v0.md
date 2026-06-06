# Track: Changefeed Production Diagnostics v0

Status date: 2026-05-04
Status: done
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Turn Changefeed from a working event delivery subsystem into an operator-visible
production surface.

The previous slices proved event buffering, replay cursors, SSE transport,
async fan-out, delivery policies, and live subscriber snapshots. This slice
should add the missing diagnostic memory and alert pressure so operators can
answer:

- Is delivery healthy right now?
- Which subscribers are slow or overloaded?
- Did any subscriber fail recently?
- Are we dropping events because queues are too small?
- Should `/v1/status` show a warning before users notice lost liveness?

Do not implement Rust here. This is the Ruby contract that a future Rust data
plane should mirror.

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/tracks/changefeed-events-v0.md`
4. `docs/tracks/changefeed-ordering-replay-v0.md`
5. `docs/tracks/changefeed-sse-events-v0.md`
6. `docs/tracks/changefeed-async-fanout-v0.md`
7. `docs/tracks/changefeed-delivery-policy-observability-v0.md`
8. this track

Do not read the whole repository unless a failing test forces a wider search.

## Current Baseline

`changefeed-delivery-policy-observability-v0` landed:

```text
ChangefeedBuffer
  -> bounded retained event ring
  -> replay(cursor:, stores:, limit:)
  -> async per-subscriber queues
  -> overflow policies: :drop_oldest / :drop_newest
  -> close policies: :drain / :discard
  -> live subscriber_snapshot
  -> aggregate snapshot fields:
       subscriber_count, subscriber_queue_size, total_queued,
       dropped_total, overflow_dropped_total, delivered_total, failed_total
```

Known limits:

- Failed/closed subscribers disappear from `subscriber_snapshot`.
- Post-mortem diagnosis only has aggregate `failed_total`.
- Queue pressure does not yet produce explicit alerts.
- `/v1/status` includes changefeed snapshot but does not yet interpret it.
- There is no bounded recent-failures / recent-delivery-events ring.

## Scope

Implement production diagnostics around existing Changefeed behavior:

- Add a bounded diagnostic ring for subscriber lifecycle/delivery incidents.
- Record at least:
  - subscriber subscribed
  - subscriber closed
  - subscriber failed with error class/message
  - subscriber queue overflow/drop
  - optional queue pressure threshold crossing
- Keep diagnostic entries serializable and compact. Do not store raw events or
  Ruby `Thread` / `Queue` objects.
- Add `ChangefeedBuffer#diagnostics_snapshot` or extend `#snapshot` with a
  compact diagnostic section.
- Add configurable alert thresholds at construction time, for example:

```ruby
ChangefeedBuffer.new(
  subscriber_queue_size: 100,
  overflow: :drop_oldest,
  close_policy: :drain,
  diagnostic_ring_size: 100,
  alert_thresholds: {
    total_queued: 500,
    overflow_dropped_total: 10,
    failed_total: 1,
    queue_pressure_ratio: 0.8
  }
)
```

- Surface changefeed alerts through `LedgerServer#observability_snapshot`.
- Ensure HTTP `/v1/status` exposes the same canonical alert signal through the
  existing status provider path.
- Preserve existing SSE and TCP behavior.

## Suggested Snapshot Shape

Prefer a compact additive shape:

```ruby
buffer.snapshot
# => {
#      ...existing_fields,
#      alerts: [
#        { code: :changefeed_queue_pressure, severity: :warning, ... }
#      ],
#      diagnostics: {
#        recent: [
#          { type: :subscriber_failed, subscriber_id: "...", ts: "...", error_class: "...", message: "..." }
#        ],
#        recent_count: 12,
#        dropped_diagnostics_total: 3
#      }
#    }
```

or:

```ruby
buffer.diagnostics_snapshot
```

Choose the smaller implementation, but keep the result JSON-friendly and stable
enough for `/v1/status`.

## Alert Guidance

Use warnings, not hard failures. The server can be alive and ready while event
delivery is degraded.

Candidate alert codes:

- `:changefeed_queue_pressure`
- `:changefeed_overflow_drops`
- `:changefeed_subscriber_failures`
- `:changefeed_no_subscribers` only if this is clearly useful and opt-in

Do not alert on every individual dropped event. Use thresholds to avoid noisy
status output.

## Acceptance

- Full package test suite passes.
- Existing changefeed/SSE/TCP specs stay green.
- Failed subscriber details are visible after the subscriber is removed from
  the live snapshot.
- Closed subscriber lifecycle can be diagnosed without keeping it active.
- Overflow/drop diagnostics are observable separately from retained ring drops.
- `ChangefeedBuffer#snapshot` or `#diagnostics_snapshot` exposes recent
  diagnostic entries and diagnostic drop count.
- `LedgerServer#observability_snapshot` includes changefeed alerts.
- HTTP `/v1/status` exposes those alerts through the canonical status shape.
- Thresholds are configurable at construction and validated early.
- Unknown threshold keys either raise early or are ignored deliberately with a
  documented decision.
- Diagnostic rings are bounded; no unbounded memory growth.

## Non-Goals

- No Rust implementation.
- No durable subscriber registry.
- No durable subscriber checkpoints.
- No WebSocket/webhook transport.
- No auth/TLS.
- No cluster replication.
- No public v1 API promise.
- No change to fact persistence format.

## Rust-Readiness Constraints

- Keep diagnostics and alerts serializable.
- Keep alert codes symbolic/string-friendly.
- Keep handler errors summarized, not stored as Ruby exception objects.
- Keep the diagnostic ring independent from transport adapters.
- Avoid leaking thread/condition-variable implementation details.
- Make the resulting contract easy to mirror in a Rust worker/runtime.

## Suggested Files To Inspect

```text
lib/igniter/store/changefeed_buffer.rb
lib/igniter/store/store_server.rb
lib/igniter/store/http_adapter.rb
spec/igniter/store/changefeed_spec.rb
spec/igniter/store/store_server_spec.rb
spec/igniter/store/http_adapter_spec.rb
docs/store-server-production-surface.md
docs/tracks/changefeed-delivery-policy-observability-v0.md
```

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/changefeed-production-diagnostics-v0
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
