# igniter-ledger-client

Protocol-first client package for Igniter Ledger / Ledger Open Protocol.

Status: pre-v1 skeleton. This package owns the client boundary, not the storage
engine.

## Purpose

`igniter-ledger-client` is the shared client layer for packages and host apps
that need to talk to a Ledger/Store endpoint without depending on
`igniter-ledger` internals.

```text
Embed / Companion / Web / MCP / Spark adapters
  -> Igniter::LedgerClient
  -> Ledger Open Protocol envelope
  -> local dispatch | remote HTTP | future TCP/pool/outbox transport
```

The package deliberately has no runtime dependency on `igniter-ledger`.

## Owns

- request/response envelope helpers
- client error semantics
- stable Ruby method surface for common Ledger operations
- transport adapters such as object dispatch and remote HTTP
- future pooling, timeout, retry, and backpressure policy seams

## Does Not Own

- fact storage engine
- WAL, segments, compaction, or changefeed internals
- contract execution
- Rails, Sidekiq, ActiveRecord, or Spark-specific code
- Store-to-Ledger package rename

## Example

```ruby
require "igniter-ledger-client"

client = Igniter::LedgerClient.remote_http(
  "http://127.0.0.1:7300/v1/dispatch",
  open_timeout: 1.0,
  read_timeout: 2.0
)

client.write(
  store: :orders,
  key: "order-1",
  value: { status: :open },
  producer: { type: :app, name: :spark }
)

client.append(
  history: :order_events,
  event: { event_id: "evt-1", order_id: "order-1", event: :opened },
  partition_key: :order_id,
  producer: { type: :app, name: :spark }
)

client.read(store: :orders, key: "order-1")
```

For local/integration tests, wrap any object exposing `dispatch(envelope)` or
`wire.dispatch(envelope)`:

```ruby
client = Igniter::LedgerClient.wrap(protocol_interpreter.wire)
client.metadata_snapshot
```

When `igniter-ledger` is present in the same process, wrapping
`LedgerStore#protocol` is the local adoption path:

```ruby
ledger = Igniter::Ledger::LedgerStore.new
client = Igniter::LedgerClient.wrap(ledger.protocol)
```

Package-level adapters should prefer accepting a `client:` argument over
reaching into Ledger internals. For example, `ContractableReceiptSink` can be
constructed with `client: client` and still use the same protocol envelope path
as a remote HTTP client.

## v0 Surface

```ruby
client.register_descriptor(...)
client.write(store:, key:, value:, **metadata)
client.append(history:, event:, key: nil, partition_key: nil, **metadata)
client.read(store:, key:, as_of: nil)
client.query(store:, where:, limit: nil, as_of: nil, order: nil)
client.replay(
  store: nil,
  from: nil,
  to: nil,
  key: nil,
  partition_key: nil,
  partition_value: nil,
  filter: nil
)
client.resolve(relation:, from:, as_of: nil)
client.causation_chain(store:, key:)
client.lineage(store:, key:)
client.fact_ref(fact_id)
client.subscribe(stores:, cursor: nil) { |event| ... }
client.metadata_snapshot
client.descriptor_snapshot
client.observability_snapshot
client.compaction_activity(store: nil, kind: nil, since: nil, limit: nil)
client.close
```

`append` dispatches the Ledger Open Protocol `append` op and keeps append-only
history semantics distinct from keyed record writes. `key:` may be sent as
client metadata for future idempotency work, but protocol v0 returns the
generated fact key and does not treat `key:` as a stable idempotency guarantee.

`replay` accepts either an explicit protocol `filter:` or convenience arguments
for store, key, and partition replay. Partition replay sends
`filter: { store:, partition_key:, partition_value: }` and uses Ledger
partition indexes when the endpoint is backed by a Ledger protocol interpreter.

`subscribe` returns an idempotently closeable handle and yields
`Igniter::LedgerClient::Results::ChangeEventResult` objects. Remote HTTP
subscriptions read SSE from `/v1/events`; `events_url:` can be passed explicitly,
otherwise it is derived from `/v1/dispatch`. Cursor resume uses the `?cursor=`
query parameter.

## Docs

- [docs/tracks/ledger-client-protocol-v0.md](docs/tracks/ledger-client-protocol-v0.md)
  — current implementation/convergence track for this package.

## Error Policy

The client raises `Igniter::LedgerClient::Error` for protocol error envelopes
and `Igniter::LedgerClient::TransportError` for transport failures.

Successful mutation/read calls return small result objects:

- `write` -> `Igniter::LedgerClient::Results::WriteResult`
- `append` -> `Igniter::LedgerClient::Results::AppendResult`
- `register_descriptor` -> `Igniter::LedgerClient::Results::ReceiptResult`
- `read` -> `Igniter::LedgerClient::Results::ReadResult`
- `query` -> `Igniter::LedgerClient::Results::QueryResult`
- `resolve` -> `Igniter::LedgerClient::Results::ResolveResult`
- `replay` -> `Igniter::LedgerClient::Results::ReplayResult`
- `causation_chain` -> `Igniter::LedgerClient::Results::CausationChainResult`
- `lineage` -> `Igniter::LedgerClient::Results::LineageResult`
- `fact_ref` -> `Igniter::LedgerClient::Results::FactRefResult`
- `subscribe` events -> `Igniter::LedgerClient::Results::ChangeEventResult`

Result objects expose named readers, `to_h`, and transitional `[]` access.
`QueryResult#items` is the canonical row shape for query consumers and includes
`{ key:, value: }` entries; `QueryResult#results` remains the backward-compatible
value-only list. `ResolveResult` follows the same `items`/`results` convention
so typed clients can preserve source record keys.
`causation_chain`, `lineage`, and `fact_ref` are read-only provenance
introspection calls. `fact_ref` returns compact metadata only; arbitrary
`fact_by_id` value reads remain outside the public client surface.
Snapshot-style methods such as `metadata_snapshot` and `observability_snapshot`
still return raw protocol hashes in v0.

## Package Boundary

`igniter-embed` should not own Store connections, pools, retries, or
backpressure. Embed emits receipts to an adapter protocol. The adapter can then
use `igniter-ledger-client` to deliver those receipts locally, remotely, or
through a host outbox.
