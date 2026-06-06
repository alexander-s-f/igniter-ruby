# Track: Changefeed Delivery Policy + Observability v0

Status date: 2026-05-04
Status: done
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Harden the Ruby Changefeed delivery contract before any Rust data-plane move:
make subscriber queue policy, close behavior, per-subscriber state, and
backpressure observability explicit and testable.

This is the next large slice after async fan-out. Do not implement Rust here.

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/tracks/changefeed-events-v0.md`
4. `docs/tracks/changefeed-ordering-replay-v0.md`
5. `docs/tracks/changefeed-sse-events-v0.md`
6. `docs/tracks/changefeed-async-fanout-v0.md`
7. this track

Do not read the whole repository unless a failing test forces a wider search.

## Current Baseline

`changefeed-async-fanout-v0` landed:

```text
emit
  -> append ChangeEvent to retained ring
  -> enqueue event into matching subscriber queues
  -> return quickly

subscriber worker
  -> drains bounded queue
  -> calls transport handler
  -> updates delivered/failed/overflow counters
```

Current known limits:

- `Subscription#close` drains pending events and joins worker up to 2 seconds.
- `:drop_oldest` is the main tested overflow policy.
- `:drop_newest` exists as code path but needs explicit contract/spec coverage.
- `snapshot` is mostly global; per-subscriber diagnosis is still thin.
- There is no close policy (`:drain` vs `:discard`) exposed yet.

## Scope

Implement delivery policy and observability hardening:

- Add explicit subscriber close policy:

```ruby
ChangefeedBuffer.new(
  subscriber_queue_size: 100,
  overflow: :drop_oldest,
  close_policy: :drain # or :discard
)
```

- Define and test:
  - `:drain`: close delivers queued events before worker exits.
  - `:discard`: close drops queued events and exits quickly.
- Keep `:drain` as default unless the implementation shows a safer default.
- Fully specify and test overflow policies:
  - `:drop_oldest`
  - `:drop_newest`
  - unknown policy rejects early with clear `ArgumentError`.
- Add per-subscriber state to `snapshot` or a new `subscriber_snapshot`:

```ruby
{
  id: "...",
  stores: ["tasks"],
  queue_size: 3,
  queue_max_size: 100,
  overflow: :drop_oldest,
  close_policy: :drain,
  delivered_total: 42,
  overflow_dropped_total: 7,
  failed_total: 0,
  status: :active | :closing | :closed | :failed
}
```

- Preserve existing global counters.
- Add enough observability fields for operators to answer:
  - Which subscriber is slow?
  - Which queue is near full?
  - How many events were dropped for delivery vs retained replay?
  - Did a subscriber fail or close cleanly?
- Surface aggregate queue state through `ChangefeedBuffer#snapshot`.
- Keep SSE and TCP compatibility.

## Suggested API Shape

Prefer additive API:

```ruby
buffer.snapshot
buffer.subscriber_snapshot
```

or:

```ruby
buffer.snapshot[:subscribers]
```

Choose the simpler form, but avoid leaking Ruby `Thread` or `Queue` objects.

## Acceptance

- Full package test suite passes.
- Slow subscriber still does not stall `emit`.
- `:drop_oldest` and `:drop_newest` are both tested and documented.
- Unknown overflow policy raises early.
- `:drain` close policy drains queued events and exits.
- `:discard` close policy drops queued events and exits quickly.
- `Subscription#close` remains idempotent.
- Per-subscriber snapshot exposes queue size, policy, counters, and status.
- Global snapshot exposes aggregate queue/backpressure health.
- SSE `/v1/events` still releases subscription on body close.
- TCP `fact_written` compatibility remains green.

## Non-Goals

- No Rust implementation.
- No durable subscriber checkpoints.
- No persistent subscriber registry.
- No auth/TLS.
- No cluster replication.
- No WebSocket/webhook.
- No public v1 API promise.

## Rust-Readiness Constraints

- Keep policy names serializable (`:drop_oldest`, `:drop_newest`, `:drain`,
  `:discard`).
- Keep ChangefeedBuffer public API stable.
- Keep transport handlers outside core Changefeed internals.
- Do not expose Ruby thread/condition-variable details in public snapshots.
- Make counters and policy names suitable for a future Rust mirror.

## Suggested Files To Inspect

```text
lib/igniter/store/changefeed_buffer.rb
lib/igniter/store/http_adapter.rb
lib/igniter/store/store_server.rb
spec/igniter/store/changefeed_spec.rb
spec/igniter/store/http_adapter_spec.rb
spec/igniter/store/network_backend_spec.rb
spec/igniter/store/store_server_spec.rb
docs/rust-native-data-plane-plan.md
```

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/changefeed-delivery-policy-observability-v0
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
