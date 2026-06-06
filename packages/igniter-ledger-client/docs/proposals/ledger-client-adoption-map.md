# Ledger Client Adoption Map

Status: proposal
Owner: [Architect Supervisor / Codex]
Status date: 2026-05-04

## Purpose

Define where `igniter-ledger-client` should become the standard boundary and
where direct `igniter-ledger` engine APIs should remain acceptable.

The goal is not to hide Ledger. The goal is to prevent every package from
inventing its own transport, retry, envelope, error, and remote/local switching
shape.

## Core Rule

Use direct `igniter-ledger` APIs only when the caller is part of the Ledger
engine or an embedded test/proof.

Use `igniter-ledger-client` when a package, host app, adapter, or integration
needs to talk to Ledger as a service, protocol endpoint, or swappable local/
remote capability.

```text
Ledger engine internals
  -> direct Igniter::Ledger / Igniter::Store implementation APIs

Packages and host apps
  -> Igniter::LedgerClient
  -> local object dispatch | remote HTTP | future TCP/pool/outbox transport
```

## Current Adoption

| Consumer | Current path | Target path | Status |
|----------|--------------|-------------|--------|
| `ContractableReceiptSink` | `store:` embedded engine | `store:` or `client:` | first adoption proof landed |
| `igniter-ledger-client` specs | fake dispatch / remote HTTP shell | stay package-local, no engine dependency | landed |
| `igniter-durable-model` local store | direct embedded Ledger engine | direct embedded is acceptable for local app facade | keep for now |
| `igniter-durable-model` network backend | `Igniter::Store::NetworkBackend` | `LedgerClient` remote/local boundary | landed |
| `igniter-embed` receipt delivery | adapter protocol, no Ledger dependency | adapters may use `LedgerClient` | candidate |
| Spark CRM integration | not in repo | app-level `LedgerClient` adapter/pool/outbox | future external adoption |
| MCP/HTTP adapters | direct protocol/server adapters | may remain server-side implementation | keep |
| `NetworkBackend` | legacy backend transport | internal/legacy compatibility path | do not expand |

## Boundary Vocabulary

`LedgerClient` should own:

- request envelope construction
- protocol error normalization
- transport errors
- remote HTTP transport
- future TCP transport
- future connection pool
- future retry/backpressure policy
- local object dispatch for tests and embedded deployments

`igniter-ledger` should own:

- facts
- WAL/segments/codecs
- protocol interpreter
- wire envelope routing
- server adapters
- changefeed
- compaction and boundaries
- native data plane

`igniter-durable-model` should own:

- Record/History developer ergonomics
- schema manifests
- app-facing typed receipts
- local product workflow semantics
- optional `LedgerClient` injection for remote Ledger deployments

## Migration Order

### M0: contractable sink proof

Status: landed.

`ContractableReceiptSink` accepts `client:`. This proves adapters can depend on
the client boundary without forcing Ledger engine internals into every caller.

### M1: protocol append

Status: landed.

Make `LedgerClient#append` a real protocol operation instead of lowering to
`write`. This closes the biggest semantic gap for histories/events.

### M2: client read result models

Status: landed.

Normalize the return values for:

- `read`
- `query`
- `replay`
- `append`
- `write`

Common client mutation/read methods return small immutable result objects.
Snapshot-style metadata and observability methods intentionally remain raw
hashes until a later slice proves a stable model is worth the added surface.

### M3: Durable Model remote boundary

Add a Durable Model store construction path that accepts a `LedgerClient`.

Possible shape:

```ruby
client = Igniter::LedgerClient.remote_http("http://127.0.0.1:7300/v1/dispatch")
store = Igniter::DurableModel::Store.new(client: client)
```

The local embedded path can keep using `Igniter::Ledger::LedgerStore`. The
network path should stop growing around `NetworkBackend` and move toward the
client boundary.

### M4: host app adapter/pool/outbox

For Rails/Spark CRM style deployments, add host-owned infrastructure around the
client:

- connection pool
- timeout defaults
- retry policy
- outbox write-through option
- observability hooks
- auth headers

This should not live in `igniter-ledger` core. It may live in
`igniter-ledger-client`, `igniter-embed`, or app-specific adapter packages
depending on how generic the proof becomes.

## Non-Goals

- Do not make `igniter-ledger-client` depend on `igniter-ledger`.
- Do not remove `NetworkBackend` while existing tests and demos depend on it.
- Do not force local embedded app paths through HTTP.
- Do not hide fact/store/history semantics behind ORM words.
- Do not rename `:igniter_store` protocol token in this adoption work.

## Open Questions

1. Should `LedgerClient.wrap` accept a raw `Igniter::Ledger::LedgerStore` and
   automatically use `store.protocol`, or should callers stay explicit?
2. Should client read models be structs, hashes with stable keys, or protocol
   receipts extended consistently?
3. Does Durable Model need more `client:` coverage first, or should the next consumer be
   `igniter-embed`/Spark-style receipt delivery?
4. Should `NetworkBackend` eventually become an implementation of a
   `LedgerClient` TCP transport, or remain a legacy embedded backend?

## Recommended Next Tracks

1. `ledger-client-append-protocol-boundary-v0`
2. `ledger-client-result-models-v0`
3. `companion-ledger-client-remote-boundary-v0` (landed against Durable Model)
