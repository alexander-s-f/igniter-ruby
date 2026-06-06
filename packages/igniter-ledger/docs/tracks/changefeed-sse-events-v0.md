# Track: Changefeed SSE Events v0

Status date: 2026-05-03
Status: done
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Add the first non-TCP pusher for Changefeed: HTTP Server-Sent Events at
`GET /v1/events`.

This slice must be a transport over the existing Changefeed ordering/replay
contract. Do not invent new event semantics in the HTTP layer.

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/tracks/changefeed-events-v0.md`
4. `docs/tracks/changefeed-ordering-replay-v0.md`
5. this track

Do not read the whole repository unless a failing test forces a wider search.

## Current Baseline

Already landed:

```text
Fact -> ChangeEvent -> ChangefeedBuffer
  -> #subscribe(stores:) for live push
  -> #replay(cursor:, stores:, limit:) for retained catch-up
```

Ordering policy is source-first:

```text
source fact event -> derived/scatter fact events
```

Replay cursor is in-memory only:

```text
nil cursor          -> retained events from oldest
{ sequence: N }     -> retained events after N
too old             -> :cursor_too_old
after newest        -> empty :ok
```

## Scope

Implement SSE v0:

- Add `GET /v1/events` to the HTTP surface used by `LedgerServer`.
- Use `ChangefeedBuffer#replay` for initial catch-up.
- Use `ChangefeedBuffer#subscribe` for live events after catch-up.
- Support store filtering from query params, e.g. `?store=tasks` or
  `?stores=tasks,reminders`.
- Support cursor input:
  - `Last-Event-ID` header maps to `{ sequence: N }`
  - optional `?cursor=N` may be accepted for simple clients/tests
- Emit SSE frames with:

```text
id: <sequence>
event: fact_committed
data: <ChangeEvent#to_h JSON>

```

- On replay cursor too old, return a clear non-stream response. Suggested:
  HTTP `409` JSON with `status: "cursor_too_old"` and oldest/newest cursors.
- Keep TCP `fact_written` compatibility unchanged.
- Add tests for replay catch-up, live delivery, store filter, Last-Event-ID,
  cursor-too-old, and clean disconnect.

## Suggested Implementation Shape

Prefer a small handler/adapter over embedding logic deep inside LedgerServer:

```text
HTTPAdapter::EventsHandler or LedgerServer SSE helper
  -> parse cursor/stores
  -> replay retained events
  -> stream SSE frames
  -> subscribe for live events
  -> close subscription on disconnect
```

If Rack streaming is awkward in the current test setup, keep the implementation
minimal but preserve the endpoint and wire contract. A small internal IO-like
stream object is acceptable for specs.

## Acceptance

- Full package test suite passes.
- `/v1/events` streams retained events from replay before live events.
- SSE `id` equals `event.cursor[:sequence]`.
- SSE `event` is `fact_committed`.
- SSE `data` is compact `ChangeEvent#to_h` JSON and does not include full
  `fact`.
- `Last-Event-ID: N` resumes after sequence `N`.
- Store filtering works for replay and live events.
- Cursor-too-old is explicit and does not silently start at oldest retained.
- Subscriber handle closes on disconnect/error.
- Observability counters remain coherent after SSE subscribers.

## Non-Goals

- No WebSocket.
- No webhook adapter.
- No durable checkpoints.
- No async fan-out / per-subscriber queue yet.
- No browser UI.
- No auth/TLS.

## Risks To Watch

- Rack streaming can be awkward depending on server/test environment. Keep the
  code small and testable.
- A blocking SSE client can still block synchronous fan-out. Do not solve this
  here unless unavoidable; record it for the async fan-out slice.
- LedgerServer currently owns a `ChangefeedBuffer`; make sure `/v1/events` is
  backed by that same buffer, not a new isolated buffer.

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/changefeed-sse-events-v0
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
