# Track: Ledger Client Append Protocol Boundary v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target packages:

- `packages/igniter-ledger`
- `packages/igniter-ledger-client`

## Context

`igniter-ledger-client` now exists as the protocol-first client boundary.
`ContractableReceiptSink` has the first adoption proof: it accepts either
`store:` or `client:`.

Current gap:

```ruby
client.append(...)
```

still lowers to Ledger Open Protocol op `:write`, because the protocol does not
yet expose a real append/history operation.

That is acceptable for the first proof, but weak for high-volume histories,
contractable events, sensor events, and Spark CRM lead/telephony/geolocation
signals.

## Goal

Add a first-class append operation through every protocol/client plane:

```text
LedgerClient#append
  -> envelope op :append
  -> Protocol::WireEnvelope
  -> Protocol::Interpreter#append
  -> IgniterStore#append
  -> receipt/result
```

The embedded store path must keep working, but protocol clients should no
longer encode append-only history events as record writes.

## Non-Goals

- Do not change the `:igniter_store` wire protocol token in this slice.
- Do not rename `Igniter::Store` internals.
- Do not redesign `History[T]`.
- Do not introduce a durable subscriber/outbox model.
- Do not change compaction/boundary semantics.
- Do not require `igniter-ledger` as a runtime dependency of
  `igniter-ledger-client`.

## Suggested Read Set

Read in this order:

1. `packages/igniter-ledger/docs/package-agent-onboarding.md`
2. `packages/igniter-ledger-client/docs/tracks/ledger-client-protocol-v0.md`
3. `packages/igniter-ledger-client/docs/tracks/ledger-client-contractable-sink-adoption-v0.md`
4. this track
5. `packages/igniter-ledger-client/lib/igniter/ledger_client/client.rb`
6. `packages/igniter-ledger-client/lib/igniter/ledger_client/envelope.rb`
7. `packages/igniter-ledger/lib/igniter/store/protocol/interpreter.rb`
8. `packages/igniter-ledger/lib/igniter/store/protocol/wire_envelope.rb`
9. `packages/igniter-ledger/lib/igniter/store/igniter_store.rb`
10. `packages/igniter-ledger/lib/igniter/store/contractable_receipt_sink.rb`

## Implementation Scope

### 1. Client Envelope

Add `:append` to `Igniter::LedgerClient::Envelope::OPERATIONS`.

Update `LedgerClient#append` so it dispatches `:append`, not `:write`.

Expected packet shape:

```ruby
{
  history: :contractable_events,
  event: { ... },
  key: "optional-explicit-event-key",
  partition_key: :observation_id,
  producer: { ... },
  valid_time: ...,
  schema_version: 1
}
```

`key:` may remain client-side metadata for future idempotency, but if the
engine cannot use explicit event keys yet, document that `key:` is not a stable
idempotency guarantee in v0.

### 2. Protocol Interpreter

Add `Protocol::Interpreter#append`.

It should call `@store.append` and return a receipt/result with enough fields
for client callers:

- accepted status
- history/store name
- fact id
- value hash
- generated key if available

Prefer reusing or extending `Protocol::Receipt` instead of inventing a second
receipt shape.

### 3. Wire Envelope

Add `:append` to `Protocol::WireEnvelope::OPERATIONS` and route it to
`Protocol::Interpreter#append`.

Keep request/response envelope shape unchanged.

### 4. ContractableReceiptSink

Keep both paths working:

- `store:` path may call embedded `store.append`
- `client:` path should now call `client.append` and receive the new append
  receipt/result

Update specs to assert the client-backed sink emits op `:append`, not `:write`.

### 5. Docs

Update:

- `packages/igniter-ledger-client/README.md`
- `packages/igniter-ledger-client/docs/tracks/ledger-client-protocol-v0.md`
- `packages/igniter-ledger-client/docs/tracks/ledger-client-contractable-sink-adoption-v0.md`
- `packages/igniter-ledger/docs/open-protocol.md` if it lists operations

The docs should state:

- `append` is now first-class in protocol v0
- `append` is append-only history semantics
- `key:` is not a stable idempotency guarantee unless/ until engine support is
  explicitly implemented

## Acceptance

Done means:

- `LedgerClient#append` dispatches op `:append`
- `Envelope::OPERATIONS` includes `:append`
- `Protocol::WireEnvelope::OPERATIONS` includes `:append`
- `Protocol::Interpreter#append` exists and calls embedded append semantics
- client-backed `ContractableReceiptSink#record_event` uses protocol append
- embedded `store:` sink path still passes
- read helpers still work through client-backed replay/read
- old `write` op behavior is unchanged
- no `:igniter_store` token rename

Required tests:

```bash
bundle exec rspec packages/igniter-ledger-client/spec
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec \
  packages/igniter-ledger/spec/igniter/store/contractable_receipt_sink_spec.rb \
  packages/igniter-ledger/spec/igniter/store/protocol
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec
BUNDLE_GEMFILE=packages/igniter-companion/Gemfile bundle exec rspec packages/igniter-companion/spec
```

If full ledger specs require local sockets, run them outside sandbox as usual.

## Handoff Format

At the end, respond with:

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/ledger-client-append-protocol-boundary-v0
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

- `LedgerClient#append` dispatches envelope op `:append`.
- `Igniter::LedgerClient::Envelope::OPERATIONS` includes `:append`.
- `Igniter::Store::Protocol::WireEnvelope::OPERATIONS` includes `:append`.
- `Protocol::Interpreter#append` delegates to `IgniterStore#append` and returns
  an append receipt with accepted status, history/store name, generated key,
  fact id, value hash, and warnings.
- `ContractableReceiptSink#record_event` uses `client.append` on the client
  path and embedded `store.append` on the store path.
- `append` accepts `producer`, `valid_time`, `schema_version`, and
  `partition_key`; client-supplied `key:` remains metadata only in v0.
- The `:igniter_store` protocol token and `Igniter::Store` internals were not
  renamed.
