# Track: Companion Ledger Client Scope Subscriptions v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target packages: `packages/igniter-ledger-client`, `packages/igniter-companion`, `packages/igniter-ledger`

## Context

Client-backed Companion now supports the practical read/write surface:

- `register`
- `write`
- `read`
- `append`
- plain `replay`
- `scope` through `LedgerClient#query`

The next visible gap is `on_scope`.

Embedded Companion can do:

```ruby
store.on_scope(Reminder, :open) do |_store_name, records|
  # refresh UI, notify workflow, update derived view
end
```

Client-backed Companion still raises `NotImplementedError` because
`igniter-ledger-client` does not yet expose a standard events/subscription
boundary. Ledger itself already has changefeed and HTTP SSE `/v1/events`, so
the correct direction is to make the client own the protocol/transport surface
and let Companion consume that single standard interface.

## Goal

Add a v0 client events boundary and use it to implement client-backed
`Igniter::Companion::Store#on_scope`.

Desired app shape:

```ruby
client = Igniter::LedgerClient.remote_http(
  "http://127.0.0.1:7300/v1/dispatch",
  events_url: "http://127.0.0.1:7300/v1/events"
)

store = Igniter::Companion::Store.new(client: client)
store.register(Reminder)

sub = store.on_scope(Reminder, :open) do |_store_name, records|
  puts records.map(&:title)
end

store.write(Reminder, key: "r1", title: "Buy milk", status: :open)
sub.close
```

## Required Shape

### 1. LedgerClient event result model

Add a normalized client-side event model, for example:

```ruby
Igniter::LedgerClient::Results::ChangeEventResult
```

Minimum fields:

- `sequence`
- `store`
- `key`
- `fact_id`
- `value_hash`
- `cursor`
- `raw`

Guidance:

- Normalize symbol/string keys.
- Do not depend on `Igniter::Store::Fact` or `Igniter::Ledger` runtime classes.
- Keep the model small; it is a transport event, not a full engine fact.

### 2. LedgerClient subscription handle

Expose a common API:

```ruby
subscription = client.subscribe(stores: [:reminders], cursor: nil) do |event|
  # event is ChangeEventResult
end

subscription.close
```

The handle should be idempotently closeable.

### 3. Remote HTTP SSE transport

Teach `Igniter::LedgerClient::Transports::RemoteHTTP` how to consume Ledger
SSE from `/v1/events`.

Guidance:

- Accept `events_url:` explicitly.
- It is acceptable to derive `events_url` from a dispatch URL ending in
  `/v1/dispatch`, but explicit `events_url:` should win.
- Support `stores:` query params.
- Support `cursor:` by sending either `?cursor=` or `Last-Event-ID`; choose one
  and document it.
- Parse SSE frames with `id:`, `event:`, and `data:` lines.
- Convert each event data payload into `ChangeEventResult`.
- Run the blocking SSE reader on a background thread.
- `close` should stop the reader and join with a short timeout.
- Network failure should close the subscription and optionally expose the error
  on the handle; do not invent retry/backoff in this slice.

### 4. Local object dispatch subscription

For tests and embedded proof, `LedgerClient.wrap(object)` should support
subscription when the wrapped object exposes a compatible changefeed source.

Suggested options:

- if target responds to `changefeed`, use `target.changefeed.subscribe`
- if target responds to `observability_snapshot` only, do not fake it
- if no event source exists, raise a clear `NotImplementedError`

Keep this adapter narrow.

### 5. Companion client-backed `on_scope`

Implement `Igniter::Companion::Store#on_scope` for `client:` mode:

- validate the declared scope exists
- subscribe to the record store through `LedgerClient#subscribe(stores: [...])`
- on each event, re-run `scope(schema_class, scope_name)`
- yield the same callback shape as embedded Companion: `store_name`, records
- return a closeable subscription handle

This is v0 invalidation-by-store-event, not a remote query planner. It is
acceptable that any fact in the store refreshes all registered scopes for that
store.

## Non-Goals

- No exactly-once delivery guarantee.
- No durable subscriber checkpoints.
- No retry/backoff policy.
- No auth/TLS.
- No WebSocket transport.
- No relation/projection/scatter remote subscriptions.
- No remote server-side named scope primitive.
- No TCP subscription migration unless it falls out naturally.

## Suggested Read Set

1. `packages/igniter-companion/docs/tracks/companion-ledger-client-scope-query-boundary-v0.md`
2. `packages/igniter-companion/lib/igniter/companion/store.rb`
3. `packages/igniter-companion/spec/igniter/companion/store_spec.rb`
4. `packages/igniter-ledger-client/lib/igniter/ledger_client/client.rb`
5. `packages/igniter-ledger-client/lib/igniter/ledger_client/transports/remote_http.rb`
6. `packages/igniter-ledger-client/lib/igniter/ledger_client/transports/object_dispatch.rb`
7. `packages/igniter-ledger-client/lib/igniter/ledger_client/results.rb`
8. `packages/igniter-ledger/lib/igniter/store/http_adapter.rb`
9. `packages/igniter-ledger/spec/igniter/store/changefeed_spec.rb`
10. Relevant SSE specs under `packages/igniter-ledger/spec`

Do not read the whole repository. This is a client/subscription boundary slice.

## Acceptance

Done means:

- `LedgerClient#subscribe(stores:, cursor:, &block)` exists.
- Remote HTTP transport can consume `/v1/events` SSE frames.
- Local object dispatch can subscribe when the wrapped object exposes a
  compatible changefeed source.
- Client subscription returns normalized event result objects.
- Subscription handles are idempotently closeable.
- Client-backed Companion `on_scope` works for declared record scopes.
- Embedded Companion `on_scope` behavior is unchanged.
- Unsupported client-backed relation/projection subscriptions still fail
  clearly.
- No dependency from `igniter-ledger-client` to `igniter-ledger`.

Required tests:

```bash
BUNDLE_GEMFILE=packages/igniter-companion/Gemfile bundle exec rspec packages/igniter-companion/spec
bundle exec rspec packages/igniter-ledger-client/spec
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec
```

If full ledger specs require local sockets, run them outside the sandbox.

## Final Notes

- Added `LedgerClient#subscribe(stores:, cursor: nil)` with normalized
  `ChangeEventResult` event objects.
- Added an idempotently closeable `Igniter::LedgerClient::Subscription` handle.
- `RemoteHTTP` can consume `/v1/events` SSE streams, derives `events_url` from a
  `/v1/dispatch` endpoint when omitted, and uses `?cursor=` for resume.
- `ObjectDispatch` can subscribe when the wrapped target exposes
  `changefeed.subscribe`; it does not fake events for non-changefeed targets.
- Client-backed `Igniter::Companion::Store#on_scope` now subscribes to store
  events, re-runs the declared scope, and yields refreshed records.
- Embedded `on_scope` behavior is unchanged.
- Relation/projection/scatter subscriptions, durable checkpoints, retries, auth,
  WebSockets, and server-side named scope primitives remain out of scope.

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-companion/companion-ledger-client-scope-subscriptions-v0
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
