# Track: Changefeed Async Fan-Out v0

Status date: 2026-05-03
Status: done
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Protect the write path from slow subscribers by moving Changefeed delivery to
bounded per-subscriber queues in Ruby.

This is a Ruby-first slice. Do not move this to Rust yet. The delivery contract
is still being shaped; Rust should come after the Ruby API and semantics are
boringly stable.

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/tracks/changefeed-events-v0.md`
4. `docs/tracks/changefeed-ordering-replay-v0.md`
5. `docs/tracks/changefeed-sse-events-v0.md`
6. this track

Do not read the whole repository unless a failing test forces a wider search.

## Current Baseline

Changefeed currently has:

```text
ChangefeedBuffer#emit
  -> append retained ChangeEvent to ring
  -> synchronous fan_out to matching subscriber handlers
```

This is correct semantically but operationally weak:

- raising handlers are removed and counted
- blocking handlers still stall `emit`
- SSE clients can therefore stall the write path

The next goal is:

```text
emit
  -> append to retained ring
  -> enqueue to matching subscriber queues
  -> return quickly

subscriber worker
  -> drains queue
  -> calls handler
  -> records delivered/failed/dropped
```

## Scope

Implement async fan-out in Ruby:

- Keep existing `ChangefeedBuffer#subscribe(stores:, &handler)` API compatible.
- Keep existing `ChangefeedBuffer#emit(fact)` return value compatible.
- Add per-subscriber bounded queues.
- Add one worker thread per subscriber or equivalent simple Ruby mechanism.
- Add explicit overflow policy. Recommended default for v0:
  `:drop_oldest`.
- Add constructor options:

```ruby
ChangefeedBuffer.new(
  max_size: 1_000,
  subscriber_queue_size: 100,
  overflow: :drop_oldest
)
```

- Close/unsubscribe must stop the worker thread and release queue resources.
- Failing subscriber handlers should be removed and counted as failed.
- Slow subscribers should not block `emit` beyond bounded queue push work.
- Preserve wildcard subscriptions (`stores: []`).
- Preserve SSE and TCP behavior.
- Extend `snapshot` with queue/overflow counters if useful.

## Counters

Keep current global counters and add enough detail to diagnose backpressure:

```text
emitted_total
delivered_total
dropped_total        # retained ring drops
failed_total
subscriber_count
queued_total         # optional
delivery_dropped_total / overflow_dropped_total
```

Naming can differ if it is clearer, but ring retention drops and subscriber
delivery drops must not be conflated silently.

## Rust-Readiness Constraints

Design the Ruby slice so a future Rust hot path can replace internals without
changing app code:

- Keep `ChangeEvent` as the external value shape.
- Keep `ChangefeedBuffer#emit`, `#subscribe`, `#replay`, `#snapshot` as the
  package-facing methods.
- Keep transport concerns out of `ChangefeedBuffer`; SSE/TCP should remain
  handlers/subscribers, not core logic.
- Do not leak Ruby `Thread` objects through public API.
- Keep overflow policy explicit and serializable.

## Acceptance

- Full package test suite passes.
- A slow subscriber does not stall `emit`.
- Queue overflow behavior is explicit and tested.
- `:drop_oldest` preserves newer events for slow subscribers.
- Raising subscriber is removed and counted as failed.
- `Subscription#close` stops delivery and releases worker resources.
- SSE live delivery still works.
- TCP `fact_written` compatibility still works.
- Replay semantics are unchanged.
- Observability snapshot exposes enough queue/backpressure state to diagnose
  slow consumers.

## Non-Goals

- No Rust implementation.
- No durable subscriber checkpoints.
- No WebSocket/webhook.
- No auth/TLS.
- No cluster replication.
- No persistent subscriber registry.

## Suggested Files To Inspect

```text
lib/igniter/store/changefeed_buffer.rb
lib/igniter/store/http_adapter.rb
lib/igniter/store/store_server.rb
spec/igniter/store/changefeed_spec.rb
spec/igniter/store/http_adapter_spec.rb
spec/igniter/store/network_backend_spec.rb
spec/igniter/store/store_server_spec.rb
```

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/changefeed-async-fanout-v0
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
