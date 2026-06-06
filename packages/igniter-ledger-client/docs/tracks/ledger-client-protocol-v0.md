# Track: Ledger Client Protocol v0

Status date: 2026-05-04
Status: ready
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Create one standard client boundary for everything that talks to
`igniter-ledger` / Ledger.

This is a foundation slice. The point is to prevent every layer from inventing
its own store client:

```text
Embed receipt sink
Companion Record/History facade
MCP remote dispatch
HTTP /v1/dispatch clients
NetworkBackend
Spark outbox / Sidekiq adapters
future Web receipt views
future Application services
```

All of them should converge on one documented client shape.

Package and client name:

```ruby
packages/igniter-ledger-client
Igniter::LedgerClient
```

`igniter-ledger-client` must remain a protocol/transport package. It must not
embed the storage engine or depend on `igniter-ledger` internals.

## Read First

Use the compact fresh-chat route:

1. `packages/igniter-ledger-client/README.md`
2. `packages/igniter-ledger-client/lib/igniter/ledger_client/client.rb`
3. `packages/igniter-ledger-client/lib/igniter/ledger_client/envelope.rb`
4. `packages/igniter-ledger/docs/package-agent-onboarding.md`
5. `packages/igniter-ledger/docs/progress.md`
6. `packages/igniter-ledger/docs/open-protocol.md`
7. `packages/igniter-ledger/docs/server-api-proposal.md`
8. `packages/igniter-ledger/lib/igniter/store/protocol/interpreter.rb`
9. `packages/igniter-ledger/lib/igniter/store/protocol/wire_envelope.rb`
10. `packages/igniter-ledger/lib/igniter/store/contractable_receipt_sink.rb`
11. this track

Do not read all docs/tracks unless a failing test forces it.

## Problem

Today there are already several almost-clients:

- `IgniterStore` direct Ruby API.
- `Protocol::Interpreter` method API.
- `Protocol::WireEnvelope` dispatch API.
- `MCPAdapter::RemoteDispatch` HTTP caller.
- `NetworkBackend` TCP backend.
- `ContractableReceiptSink` accepts a raw `store:` object.
- `igniter-companion` owns a typed facade but has historically accumulated
  product pressure and naming confusion.

This is manageable in POC, but dangerous for pre-v1:

```text
many tiny client shapes
  -> inconsistent timeouts/retries/pooling
  -> undocumented response envelopes
  -> package coupling through accidental duck typing
  -> hard migration when Store becomes Ledger language
```

We need a single contact surface before Spark, Embed, Companion, Web, MCP, and
Application all start depending on different things.

## Design Rule

The canonical client speaks **Ledger Client Protocol**.

Adapters may be local, remote, pooled, outbox-backed, or test doubles, but the
client-facing method names and return envelopes should stay stable.

```text
client method
  -> normalized request
  -> Ledger Open Protocol op where possible
  -> normalized response/result
```

Do not make `igniter-embed` own connection pools. Embed only calls
`record_observation` / `record_event`. The sink/client below Embed owns delivery
policy.

## Scope A: Client Value Object / Facade

Add a small facade class in a new package:

```ruby
Igniter::LedgerClient::Client
```

Suggested constructors:

```ruby
client = Igniter::LedgerClient.wrap(dispatch_like)
client = Igniter::LedgerClient.remote_http("http://127.0.0.1:7300/v1/dispatch")
```

Do not replace `IgniterStore` internals in this slice. Store can later provide
an integration helper that returns a LedgerClient wrapping its protocol wire.

Required methods:

```ruby
client.register_descriptor(...)
client.write(store:, key:, value:, **metadata)
client.append(history:, event:, key: nil, partition_key: nil, **metadata)
client.read(store:, key:, as_of: nil)
client.query(store:, where:, limit: nil, as_of: nil)
client.replay(store: nil, from: nil, to: nil, filter: nil)
client.metadata_snapshot
client.descriptor_snapshot
client.observability_snapshot
client.compaction_activity(store: nil, kind: nil, since: nil, limit: nil)
client.close
```

Return values should be ergonomic for Ruby callers, but remote clients must not
silently discard protocol envelope errors. Decide and document one policy:

```text
Option A: return raw normalized protocol envelopes
Option B: raise LedgerClient::Error on error envelopes and return result on ok
```

Preferred for v0: **raise on error, return result on ok**. This keeps app code
simple while making remote errors explicit.

## Scope B: Local And Remote Transports

Local/object dispatch transport:

```text
Igniter::LedgerClient.wrap(dispatch_like)
  -> dispatch(envelope) or wire.dispatch(envelope)
```

Remote HTTP transport:

```text
LedgerClient.remote_http(endpoint, timeout:, pool:)
  -> POST /v1/dispatch
  -> WireEnvelope request/response
```

Keep implementation small:

- no new gem dependency
- use `Net::HTTP`
- support open/read/write timeout options
- support `pool_size:` if natural, or explicitly document no pool in v0 and
  expose a constructor seam for v1
- normalize endpoint path to `/v1/dispatch`

If a connection pool is implemented, keep it simple and bounded:

```ruby
pool_size: 5
open_timeout: 1.0
read_timeout: 2.0
```

Do not build a full circuit breaker in this slice. Add a policy seam and docs
for future backpressure/retry.

## Scope C: Receipt Sink Uses Client Boundary

Update `ContractableReceiptSink` so it can accept the standard client without
breaking current usage:

```ruby
ContractableReceiptSink.new(store: IgniterStore.new)       # existing
ContractableReceiptSink.new(client: LedgerClient.local(...)) # new
```

Rules:

- `store:` remains supported for compatibility.
- Internally normalize to a client-like object.
- `record_observation` and `record_event` should call client methods, not reach
  through to transport-specific internals.
- Descriptor registration should go through the same client boundary.
- Query helpers can remain simple, but should also use client methods where
  practical.

## Scope D: Convergence Notes For Companion And Other Layers

Do not refactor `igniter-companion` in this slice unless it is tiny and clearly
safe.

But add a compact design note:

```text
packages/igniter-ledger/docs/ledger-client-protocol.md
```

It should define:

- canonical Ledger Client method list
- local vs remote transport responsibilities
- where pooling/retry/backpressure belongs
- how `igniter-companion` should migrate toward this client
- why Embed should not own Store connection lifecycle
- how MCP remote dispatch relates to this client
- naming note: package may still be Store, client concept is Ledger

Also update:

- `packages/igniter-ledger/README.md`
- `packages/igniter-ledger/docs/README.md`

## Scope E: Tests

Add focused specs:

- local client writes/reads via `IgniterStore`
- local client registers descriptors and exposes metadata
- local client returns compaction activity
- remote HTTP client dispatches through a fake Rack/HTTP server or a small
  local test double if existing HTTP specs already provide one
- remote error envelope raises a `LedgerClient::Error`
- `ContractableReceiptSink` accepts `client:` and existing `store:` still works
- `ContractableReceiptSink` through client still passes Embed integration proof
- no hard dependency from Embed to Store

If full remote HTTP testing is too expensive in this slice, add a transport
test double and document remote HTTP as partial. But prefer at least one real
HTTP dispatch proof if current specs already have HTTPAdapter helpers.

## Acceptance

- One documented `LedgerClient` entrypoint exists.
- Local client works against `IgniterStore`.
- Remote HTTP client lowers to Ledger Open Protocol / WireEnvelope.
- `ContractableReceiptSink` can use `client:` and remains compatible with
  `store:`.
- Existing `igniter-ledger` specs pass.
- Existing `igniter-embed` contractable specs pass.
- Docs explicitly say where pooling, retries, and backpressure belong.
- No new client implementation is added to Embed.
- No large Companion refactor in this slice.

## Non-Goals

- No Store-to-Ledger package rename.
- No full `igniter-companion` redesign.
- No Spark CRM code.
- No Sidekiq/ActiveJob implementation.
- No full circuit breaker.
- No cluster replication client.
- No auth/TLS hardening.

## Risks / Watch Points

- Avoid creating yet another wrapper that bypasses existing protocol semantics.
  Prefer lowering through `Protocol::Interpreter` / `WireEnvelope`.
- Do not overfit to HTTP only. TCP/Unix/embedded transports should remain
  possible behind the same client shape.
- Be explicit about error policy. Silent remote failures are worse than a noisy
  POC.
- Keep pool/retry as a client/delivery concern, not a contract/Embed concern.
- Be careful with naming. `LedgerClient` is a concept; `igniter-ledger` remains
  the package for now.

## Follow-Up Note: Append Boundary

As of `ledger-client-append-protocol-boundary-v0`, `LedgerClient#append`
dispatches op `:append` instead of lowering history events to op `:write`.
The client package still has no runtime dependency on `igniter-ledger`; it only
adds `:append` to the shared envelope operation list. `key:` remains client-side
metadata in protocol v0 and is not an idempotency guarantee.

## Follow-Up Note: Result Models

As of `ledger-client-result-models-v0`, common mutation/read methods return
small immutable result objects under `Igniter::LedgerClient::Results`.
Receipt-like calls expose `accepted?`, `status`, `store`, `key`, `fact_id`, and
`value_hash`; read/query/replay calls expose `value`/`found?`,
`results`/`count`, and `facts`/`count`. Snapshot-style methods remain raw hashes
until a later slice proves a stable model is worth the added surface.

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/ledger-client-protocol-v0
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
