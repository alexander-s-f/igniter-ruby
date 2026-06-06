# Track: Changefeed Events v0

Status date: 2026-05-03
Status: done — implemented by Package Agent / Companion+Store
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Turn the current ad-hoc `fact_written` subscription path into the first
explicit Changefeed subsystem over committed facts.

This is the next large vertical slice after the landed pre-v1 Fact model
migration. It should keep the package moving from "durable accumulator" toward
"Ledger with live downstream pressure" without promising durable event delivery
yet.

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. this track
4. `docs/changefeed-events-plan.md` only if more context is needed

Do not read the whole repository unless a failing test forces a wider search.

## Context

Current event-like surfaces:

```text
History event
  IgniterStore#append(history:, event:)
  durable domain payload stored as a Fact

Push subscription
  SubscriptionRegistry + LedgerNetworkBackend#subscribe
  sends fact_written after write_fact
  currently direct/synchronous enough to be fragile

Server observability event
  ServerLogger#event
  structured lifecycle/metric log lines
```

The target vocabulary:

```text
Fact -> ChangeEvent -> ChangefeedBuffer -> subscribers/pushers
```

Facts remain the source of truth. Changefeed is a delivery/cursor layer derived
from committed facts, not a second event store.

## Scope

Implement the first package-local Changefeed v0:

- Add a `ChangeEvent` value object or small immutable struct.
- Emit `ChangeEvent` after successful fact writes using the current accepted
  boundary. Do not block on durable checkpoint semantics in this slice.
- Route existing subscription delivery through change events instead of raw
  facts where practical.
- Add a bounded in-memory `ChangefeedBuffer` with recent-event retention.
- Add counters for delivered, dropped, failed, and buffered events.
- Surface changefeed state in existing observability/status snapshots.
- Keep existing `LedgerNetworkBackend#subscribe` / `fact_written` behavior green.
- Add conformance specs for event shape, filtering, slow/failing subscribers,
  bounded buffer behavior, and observability counters.

## Event Shape

Start compact:

```ruby
{
  schema_version: 1,
  id: "change_...",
  type: :fact_committed,
  store: :readings,
  key: "sensor-1",
  fact_id: "...",
  transaction_time: 1_774_123_456.123,
  emitted_at: 1_774_123_456.456,
  producer: { ... },
  causation: "...",
  cursor: { sequence: 42 }
}
```

The event may carry the full fact only where an existing transport needs it.
Prefer compact references in the core shape.

## Acceptance

- Existing package tests pass.
- Existing TCP subscribe behavior remains compatible.
- `ChangeEvent` has a stable, tested shape.
- Changefeed emission happens after the store accepts a fact.
- Slow or failing subscribers do not make the write path indefinitely stuck.
- Bounded buffer behavior is explicit and tested.
- Observability snapshot includes changefeed counters and current buffer size.
- Docs explain current delivery semantics as best-effort live push.

## Non-Goals

- No durable subscriber checkpoints yet.
- No cluster replication.
- No WebSocket/webhook adapter in this slice.
- No general workflow execution or contract callbacks inside `igniter-ledger`.
- No Rust queue ownership yet.
- No Store-to-Ledger rename.

## Suggested Files To Inspect

```text
lib/igniter/store/igniter_store.rb
lib/igniter/store/subscription_registry.rb
lib/igniter/store/network_backend.rb
lib/igniter/store/store_server.rb
lib/igniter/store/server_metrics.rb
lib/igniter/store/protocol/interpreter.rb
spec/igniter/store/*subscription*
spec/igniter/store/store_server_spec.rb
spec/igniter/store/server_observability_spec.rb
```

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/changefeed-events-v0
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
