# igniter-ledger Changefeed Events Plan

Status date: 2026-05-02
Status: Package Agent planning note, not a stable public API promise
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Purpose

Clarify the status and target architecture for events in `igniter-ledger`.

The package currently has several things called events, but not yet a complete
events subsystem. This document names the missing subsystem **Changefeed** to
avoid confusing durable domain events with transport notifications.

The possible public rename from Store to Ledger is intentionally out of scope
for this plan.

## Current Status

Three event-like surfaces already exist:

```text
History event
  IgniterStore#append(history:, event:)
  durable domain payload stored as a fact

Push subscription
  SubscriptionRegistry + LedgerNetworkBackend#subscribe
  sends fact_written after write_fact
  synchronous fan_out, no durable queue, no cursor contract

Server observability event
  ServerLogger#event
  structured lifecycle/metric log lines
```

These are useful, but they are not yet one subsystem.

## Core Decision

Changefeed events must be derived from committed facts.

```text
Fact ledger
  durable source of truth
        |
        v
Changefeed
  async notification/cursor layer over committed facts
        |
        v
Subscribers / push adapters
  TCP, SSE, WebSocket, webhook, MCP watch, cluster peer stream
```

This prevents two competing sources of truth. If the process crashes, the system
recovers from facts first, then resumes or rebuilds change delivery from cursors.

## Vocabulary

Use these names consistently:

- **Fact**: durable append-only record in the store.
- **History event**: user/domain payload stored inside a History fact.
- **Change event**: package-level notification that a fact was committed.
- **Changefeed**: asynchronous stream of change events derived from committed
  facts.
- **Subscriber**: consumer registered to receive a filtered changefeed.
- **Pusher**: adapter that delivers change events over a transport.
- **Cursor**: durable or in-memory position in the changefeed.
- **Checkpoint**: saved cursor position for a subscriber or subscription.

Avoid using plain "event" without a qualifier in new docs/code.

## Target Shape

```text
write_fact
  -> durable fact accepted by backend
  -> durability state known: buffered | flushed | checkpointed
  -> enqueue change event after the configured commit boundary
  -> async delivery to subscribers
```

Open design question:

- Should `fact_written` fire after accepted, after flushed, or after
  checkpointed?

Recommended default:

- For in-process/dev mode: fire after accepted.
- For durable/cluster mode: fire after configured durability boundary.
- Surface this as explicit policy instead of hiding it.

## Change Event Shape

Candidate internal shape:

```ruby
{
  schema_version: 1,
  id: "change_...",
  type: :fact_committed,
  store: "readings",
  key: "sensor-1",
  fact_id: "...",
  fact_timestamp: 1_774_123_456.123,
  emitted_at: 1_774_123_456.456,
  durability: "flushed",
  producer: { ... },
  causation: "...",
  cursor: { segment: "...", offset: 123 }
}
```

The event may include a compact fact reference by default and optionally include
the full fact payload for push transports that need it.

## Subsystem Components

### 1. Changefeed Buffer

Responsibilities:

- receive committed fact notifications
- assign cursors
- retain recent events within a bounded policy
- expose replay-from-cursor for live subscribers
- support backpressure/drop behavior

First implementation can be Ruby and in-memory. Rust can take over when volume
requires it.

### 2. Subscription Registry

The existing `SubscriptionRegistry` is a good seed, but it should become routing
over change events rather than direct synchronous fact handler fan-out.

Needed additions:

- subscriber id
- filter descriptor
- cursor/checkpoint state
- delivery policy
- counters for delivered/dropped/failed events

### 3. Push Adapters

Adapters should be replaceable:

- TCP framed push: existing proof
- SSE: browser-friendly `/v1/events`
- WebSocket: later interactive apps
- webhook: external integrations
- MCP watch/resource: agent-facing observation
- cluster peer stream: later distributed replication

Adapters should not decide store semantics. They deliver changefeed events.

### 4. Checkpoints

Checkpoint options:

- in-memory only for dev
- durable per-subscriber cursor facts
- storage-side compact checkpoint map
- sync-profile integration through `subscription_checkpoints`

Acceptance should require at least one explicit checkpoint story before calling
the subsystem durable.

## Delivery Semantics

The first stable spec should answer:

- At-most-once, at-least-once, or best-effort?
- Does delivery happen after accepted, flushed, or checkpointed?
- What happens when a subscriber is slow?
- What happens when the process restarts?
- How does a subscriber resume from cursor?
- Are events filtered before or after enqueue?

Recommended initial answer:

```text
Mode: best-effort live push by default
Durable mode: opt-in cursor/checkpoint replay
Backpressure: bounded queue with explicit drop counters
Source of truth: facts, not changefeed memory
```

## Observability

Expose changefeed metrics through observability snapshots:

- active subscribers
- queued events
- delivered events total
- dropped events total
- failed deliveries total
- oldest retained cursor
- newest cursor
- per-adapter subscriber counts

Do not store full observability event history in the changefeed unless a later
audit requirement demands it.

## Protocol Pressure

Ledger Open Protocol already has subscription descriptor pressure. Changefeed
should add protocol-level clarity without forcing every transport to implement
live streaming immediately.

Possible operations:

- `register_subscription`
- `subscribe` / `open_changefeed`
- `changefeed_snapshot`
- `replay_changes`
- `checkpoint_subscription`

Do not add these until the delivery semantics are written as specs.

## Package Agent Guidance

Recommended sequence:

1. Write a conformance spec that documents current TCP `fact_written` behavior.
2. Extract a `ChangeEvent` shape without changing delivery semantics.
3. Make `SubscriptionRegistry` route `ChangeEvent`, not raw `Fact`.
4. Add a bounded in-memory `ChangefeedBuffer`.
5. Add counters/observability for delivered/dropped/failed events.
6. Add one non-TCP adapter proof, preferably SSE `/v1/events`.
7. Only then consider durable checkpoints and Rust queue ownership.

Acceptance for the first implementation slice:

- Existing `LedgerNetworkBackend#subscribe` behavior stays green.
- New tests prove that change events are emitted after fact writes.
- Slow/failing subscribers do not block the write path indefinitely.
- Failed subscribers are observable.
- The system can explain whether delivery is best-effort or durable.

Non-goals:

- Do not create a second event store separate from facts.
- Do not execute contract callbacks inside `igniter-ledger`.
- Do not implement cluster replication here.
- Do not promise durable event delivery until cursor/checkpoint replay exists.

Handoff should report:

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/changefeed-events
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
