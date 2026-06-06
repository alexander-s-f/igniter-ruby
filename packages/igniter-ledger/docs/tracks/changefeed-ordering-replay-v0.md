# Track: Changefeed Ordering + Replay Cursor v0

Status date: 2026-05-03
Status: done — implemented by Package Agent / Companion+Store
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Make Changefeed v0 honest and useful by defining event ordering, replay cursors,
and replay-from-buffer behavior.

This is the next large slice after `changefeed-events-v0`. Do this before SSE or
other push transports, so every adapter sits on a clear cursor contract.

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/tracks/changefeed-events-v0.md`
4. this track
5. `docs/changefeed-events-plan.md` only if more context is needed

Do not read the whole repository unless a failing test forces a wider search.

## Current Baseline

`changefeed-events-v0` landed:

```text
Fact -> ChangeEvent -> ChangefeedBuffer -> subscribers
```

Current properties:

- `ChangeEvent` has compact reference fields and optional `fact`.
- `ChangefeedBuffer` owns ring retention, sequence, fan-out, and counters.
- `LedgerServer` uses ChangefeedBuffer for TCP `fact_written` compatibility.
- Delivery is best-effort live push.
- Cursor is currently `{ sequence: Integer }` and in-memory only.

Known gaps:

- No replay API over retained buffer.
- No explicit cursor validation or "cursor too old" result.
- No documented ordering policy for source facts vs derived/scatter facts.
- Fan-out is synchronous; blocking handlers still block the caller.

## Core Decision To Make

Changefeed sequence should represent **change event emission order**, not
necessarily original source write call order.

The important policy to specify and test:

```text
write source fact
  -> store accepts source fact
  -> derivations/scatters may write derived facts
  -> changefeed emits events in the order facts are actually emitted
```

If current implementation emits derived facts before the source fact, either:

1. accept and document depth-first emission order, or
2. change implementation so source fact is emitted before derived writes.

Choose one policy and make it explicit in docs and specs. Prefer the policy that
is easiest to reason about for external subscribers.

## Scope

Implement replay and cursor semantics on the in-memory ChangefeedBuffer:

- Add `ChangefeedBuffer#replay(cursor: nil, stores: nil, limit: nil)` or similar.
- Return retained `ChangeEvent` objects ordered by sequence.
- Support store filtering during replay.
- Define cursor semantics:
  - `nil` cursor returns retained events from oldest retained sequence.
  - `{ sequence: N }` returns events with sequence greater than `N`.
  - cursor before oldest retained sequence returns an explicit "too old" signal.
  - cursor after newest sequence returns empty result with current cursor.
- Add a small result object or hash shape for replay:

```ruby
{
  status: :ok | :cursor_too_old,
  events: [ChangeEvent],
  cursor: { sequence: newest_sequence },
  oldest_cursor: { sequence: oldest_sequence },
  newest_cursor: { sequence: newest_sequence },
  dropped_total: Integer
}
```

- Add specs for replay after ring overflow.
- Add specs for subscriber cursor handoff if easy: subscriber receives events
  and can use last cursor to replay missed retained events.
- Update observability snapshot if replay state needs clearer fields.
- Fix comments/docs that imply slow subscribers do not block the write path.

## Acceptance

- Full package test suite passes.
- Replay from nil cursor returns retained events in sequence order.
- Replay from `{ sequence: N }` returns only newer retained events.
- Overflowed ring reports cursor-too-old rather than silently pretending replay
  is complete.
- Store-filtered replay works.
- Empty replay after newest cursor is explicit and green.
- Ordering policy for source vs derived/scatter facts is documented and tested.
- Docs state v0 replay is in-memory/best-effort, not durable recovery.

## Non-Goals

- No durable checkpoints.
- No persistent subscriber registry.
- No SSE/WebSocket/webhook adapter in this slice.
- No async fan-out implementation unless it is needed to make replay safe.
- No Rust queue ownership.
- No cluster replication.

## Suggested Files To Inspect

```text
lib/igniter/store/change_event.rb
lib/igniter/store/changefeed_buffer.rb
lib/igniter/store/igniter_store.rb
lib/igniter/store/store_server.rb
spec/igniter/store/changefeed_spec.rb
spec/igniter/store/derivation_spec.rb
spec/igniter/store/scatter_spec.rb
```

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/changefeed-ordering-replay-v0
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
