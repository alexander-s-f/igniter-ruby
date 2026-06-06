# Track: Ledger Client Result Models v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-ledger-client`

## Context

`LedgerClient#append` is now a first-class protocol operation. The next weak
spot is return shape consistency.

Today `LedgerClient` returns raw protocol `result` payloads:

- local object dispatch may return `Igniter::Store::Protocol::Receipt` structs
- remote HTTP returns parsed JSON hashes
- `read` returns `{ value:, found: }`
- `query` returns `{ results:, count: }`
- `replay` returns `{ facts:, count: }`

This leaks transport shape into consumers. It also makes local and remote Ledger
clients subtly different even though the client is supposed to be the stable
boundary.

## Goal

Add small result models in `igniter-ledger-client` that normalize local and
remote protocol responses into one client-facing shape.

```text
LedgerClient
  -> protocol envelope
  -> raw protocol result
  -> LedgerClient::Result object
  -> package/host app consumer
```

The result models should keep Ledger semantics visible while removing
transport-shape ambiguity.

## Non-Goals

- Do not change the Ledger wire envelope response shape.
- Do not change `:igniter_store` protocol token.
- Do not make `igniter-ledger-client` depend on `igniter-ledger`.
- Do not hide facts/history/store vocabulary behind ORM language.
- Do not add retries, pooling, auth, or outbox behavior in this slice.
- Do not migrate Companion to `client:` in this slice.

## Suggested Read Set

1. `packages/igniter-ledger-client/docs/proposals/ledger-client-adoption-map.md`
2. `packages/igniter-ledger-client/docs/tracks/ledger-client-protocol-v0.md`
3. `packages/igniter-ledger-client/docs/tracks/ledger-client-contractable-sink-adoption-v0.md`
4. this track
5. `packages/igniter-ledger-client/lib/igniter/ledger_client/client.rb`
6. `packages/igniter-ledger-client/lib/igniter/ledger_client/envelope.rb`
7. `packages/igniter-ledger-client/spec/igniter/ledger_client/client_spec.rb`
8. `packages/igniter-ledger/spec/igniter/store/contractable_receipt_sink_spec.rb`

Only inspect `igniter-ledger` internals if a result shape is unclear.

## Proposed Result Models

Add a new file:

```text
packages/igniter-ledger-client/lib/igniter/ledger_client/results.rb
```

Suggested models:

```ruby
Igniter::LedgerClient::Results::ReceiptResult
Igniter::LedgerClient::Results::WriteResult
Igniter::LedgerClient::Results::AppendResult
Igniter::LedgerClient::Results::ReadResult
Igniter::LedgerClient::Results::QueryResult
Igniter::LedgerClient::Results::ReplayResult
```

Keep implementation lightweight. Structs or small immutable classes are enough.

### Common Expectations

All result objects should:

- expose named readers
- provide `to_h`
- provide `[]` for transitional hash-like access where cheap
- freeze themselves
- normalize string/symbol keys

Receipt-like results should:

- expose `accepted?`
- expose `status`
- expose `store`
- expose `key`
- expose `fact_id`
- expose `value_hash`
- expose `warnings`
- expose `errors`

### Operation Mapping

| Client method | Current raw result | Target result |
|---------------|--------------------|---------------|
| `write` | protocol receipt object/hash | `WriteResult` |
| `append` | append receipt object/hash | `AppendResult` |
| `register_descriptor` | descriptor receipt object/hash | `ReceiptResult` |
| `read` | `{ value:, found: }` | `ReadResult` |
| `query` | `{ results:, count: }` | `QueryResult` |
| `replay` | `{ facts:, count: }` | `ReplayResult` |
| metadata/observability/storage reads | raw hash | keep raw for now |

The last row is intentional. Do not over-model complex snapshots yet.

## Compatibility Notes

This is pre-v1, so returning result objects is acceptable, but avoid gratuitous
consumer breakage:

- `ReadResult#value` should make `ContractableReceiptSink#observation` easy.
- `ReadResult#found?` should be explicit.
- `QueryResult#results` and `ReplayResult#facts` should expose arrays.
- `ReceiptResult#accepted?` must keep sink specs natural.
- `to_h` should preserve enough of the current raw shape for debugging.

`ContractableReceiptSink` should be updated if needed to accept `ReadResult`
and `ReplayResult` cleanly.

## Acceptance

Done means:

- result models exist in `igniter-ledger-client`
- `LedgerClient#write` returns `WriteResult`
- `LedgerClient#append` returns `AppendResult`
- `LedgerClient#register_descriptor` returns `ReceiptResult`
- `LedgerClient#read` returns `ReadResult`
- `LedgerClient#query` returns `QueryResult`
- `LedgerClient#replay` returns `ReplayResult`
- remote-hash and local-object raw results normalize to the same client shape
- metadata/observability snapshot methods keep returning raw hashes
- `ContractableReceiptSink` still works with `client:`
- no dependency from `igniter-ledger-client` to `igniter-ledger`

Required tests:

```bash
bundle exec rspec packages/igniter-ledger-client/spec
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec \
  packages/igniter-ledger/spec/igniter/store/contractable_receipt_sink_spec.rb
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec
BUNDLE_GEMFILE=packages/igniter-companion/Gemfile bundle exec rspec packages/igniter-companion/spec
```

If full ledger specs require sockets, run them outside sandbox.

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-ledger-client/ledger-client-result-models-v0
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

## Final Notes

Status date: 2026-05-04.

- Added `Igniter::LedgerClient::Results` with `ReceiptResult`, `WriteResult`,
  `AppendResult`, `ReadResult`, `QueryResult`, and `ReplayResult`.
- `write`, `append`, `register_descriptor`, `read`, `query`, and `replay`
  normalize raw protocol results into result objects.
- Local receipt-like objects and remote string-key hashes normalize to the same
  client-facing shape.
- Result objects expose named readers, `to_h`, transitional `[]`, and freeze
  themselves.
- Metadata, descriptor, observability, and compaction snapshot methods remain
  raw protocol results for v0.
- `ContractableReceiptSink` accepts `ReadResult` and `ReplayResult` on the
  client-backed path.
- No `igniter-ledger` runtime dependency was added to `igniter-ledger-client`.
