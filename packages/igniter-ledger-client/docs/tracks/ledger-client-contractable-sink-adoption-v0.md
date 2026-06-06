# Track: Ledger Client Contractable Sink Adoption v0

Status: done
Owner: [Architect Supervisor / Codex]

## Decision

`igniter-ledger-client` remains a protocol/transport package and does not embed
the Ledger engine.

The first adoption proof is on the consumer side:
`Igniter::Ledger::ContractableReceiptSink` can now accept either:

- `store:` — embedded Ledger engine API
- `client:` — `Igniter::LedgerClient` / protocol client API

This keeps the old local path working while giving packages a stable protocol
boundary to depend on.

## Shape

```text
Embed contractable receipts
  -> ContractableReceiptSink
  -> store: embedded Ledger API
   | client: LedgerClient protocol API
  -> Ledger Open Protocol envelope
  -> local dispatch or remote transport
```

For local adoption:

```ruby
ledger = Igniter::Ledger::LedgerStore.new
client = Igniter::LedgerClient.wrap(ledger.protocol)
sink = Igniter::Ledger::ContractableReceiptSink.new(client: client)
```

## Notes

- `record_observation` writes through `client.write`.
- `record_event` writes through `client.append`, which now dispatches protocol
  op `:append`.
- Read helpers use protocol `read` and `replay` when only `client:` is present.
- Direct embedded `history` / `history_partition` remains used for `store:`.

## Verification

```bash
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec \
  packages/igniter-ledger/spec/igniter/store/contractable_receipt_sink_spec.rb \
  packages/igniter-ledger/spec/igniter/store/contractable_receipt_sink_integration_spec.rb

bundle exec rspec packages/igniter-ledger-client/spec
BUNDLE_GEMFILE=packages/igniter-companion/Gemfile bundle exec rspec packages/igniter-companion/spec
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec
```

Latest result:

- contractable sink focused specs: 34 examples, 0 failures
- ledger-client specs: 8 examples, 0 failures
- companion specs: 89 examples, 0 failures
- ledger specs: 1211 examples, 0 failures

## Next

Next useful boundary slices:

- define a small client-side read model for `read/query/replay` so consumers do
  not need to know raw protocol result shapes
- migrate one more consumer, likely `igniter-companion`, to accept or produce a
  `LedgerClient` boundary where remote Ledger access is needed
