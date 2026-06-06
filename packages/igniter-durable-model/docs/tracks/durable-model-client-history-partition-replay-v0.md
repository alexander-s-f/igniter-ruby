# Track: Durable Model Client History Partition Replay v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target packages: `packages/igniter-durable-model`, `packages/igniter-ledger-client`, `packages/igniter-ledger`

## Context

Durable Model now has the canonical package and namespace:

```ruby
require "igniter/durable_model"
Igniter::DurableModel
```

Client-backed Durable Model now supports the practical live app surface:

- `register`
- `write`
- `read`
- `scope`
- `on_scope`
- `append`
- plain `replay`

The remaining first user-visible gap for History is partition replay.

Embedded Durable Model supports:

```ruby
store.replay(TrackerLog, partition: "sleep")
```

Client-backed Durable Model still raises:

```text
client-backed Durable Model store does not support partition replay in v0
```

This makes remote Durable Model weaker than local Durable Model for common
append-only streams such as tracker logs, technician schedules, order events,
sensor streams, and audit trails.

## Goal

Make client-backed Durable Model support `History` partition replay using
`LedgerClient#replay` and the existing Ledger protocol replay surface.

Desired app shape:

```ruby
client = Igniter::LedgerClient.wrap(ledger.protocol)
store = Igniter::DurableModel::Store.new(client: client)

store.register(TrackerLog)
store.append(TrackerLog, tracker_id: "sleep", value: 7.0)
store.append(TrackerLog, tracker_id: "training", value: 45.0)
store.append(TrackerLog, tracker_id: "sleep", value: 8.5)

sleep_logs = store.replay(TrackerLog, partition: "sleep")
# => [#<TrackerLog value=7.0>, #<TrackerLog value=8.5>]
```

## Required Shape

### 1. Replay filter contract

Extend the protocol replay filter shape rather than introducing a separate
history-partition operation.

Recommended packet shape:

```ruby
{
  operation: :replay,
  packet: {
    from:  since,
    to:    as_of,
    filter: {
      store:           :tracker_logs,
      partition_key:   :tracker_id,
      partition_value: "sleep"
    }
  }
}
```

Also support key-filtered history replay if the same shape is easy:

```ruby
filter: {
  store: :tracker_logs,
  key:   "event-key"
}
```

Keep existing compatibility:

```ruby
filter: { store: :tracker_logs }
```

### 2. Ledger protocol implementation

In `Protocol::Interpreter#replay`:

- preserve existing behavior when no filter is given
- preserve existing `filter[:store]` behavior
- when `store + key` are present, use `@store.history(store:, key:, since:, as_of:)`
- when `store + partition_key + partition_value` are present, use
  `@store.history_partition(store:, partition_key:, partition_value:, since:, as_of:)`
- otherwise fall back to fact-log replay with simple filtering only if such
  filtering already exists or is trivial and well tested

Guidance:

- prefer engine `history_partition` for the partition case so the existing
  partition index is used
- serialize facts with the same `serialize_fact` path as existing replay
- do not change receipt formats
- do not add a new public operation unless replay cannot carry the shape cleanly

### 3. LedgerClient API

Extend `LedgerClient#replay` with optional filter arguments:

```ruby
client.replay(
  store: nil,
  from: nil,
  to: nil,
  key: nil,
  partition_key: nil,
  partition_value: nil,
  filter: nil
)
```

Rules:

- explicit `filter:` remains supported
- if `filter:` is absent, build it from `store`, `key`, `partition_key`,
  `partition_value`
- if both `filter:` and convenience args are given, either merge predictably or
  raise a clear `ArgumentError`; prefer raising if ambiguity appears

`ReplayResult#facts` should continue to be the only canonical result array.

### 4. Durable Model client adapter

Implement client-backed history partition replay:

```ruby
store.replay(history_class, partition: "sleep")
```

Mapping:

- `history_class.store_name` -> `store`
- `history_class._partition_key` -> `partition_key`
- `partition` argument -> `partition_value`
- `since:` -> `from`
- `as_of:` -> `to`

If `partition:` is given but the history class has no `partition_key`, match
embedded behavior exactly.

Also remove the client-backed key-filtered history replay gap if the protocol
filter now supports `key`.

### 5. Docs

Update Durable Model README/current docs:

- client-backed mode supports `replay(partition:)`
- remaining client-backed gaps are now relations, projection/scatter direct
  registration/snapshots, and causation chains if still unsupported

Do not overpromise performance across all transports; say this lowers through
the Ledger replay filter and uses Ledger partition indexes when served by a
Ledger protocol interpreter.

## Non-Goals

- No new History query DSL.
- No relation resolution over client.
- No projection/scatter remote registration.
- No durable cursor/checkpoint API for replay.
- No pagination for replay unless it already exists.
- No streaming replay; this is request/response replay.
- No server-side named partition concept beyond `partition_key` and
  `partition_value`.

## Suggested Read Set

1. `packages/igniter-durable-model/lib/igniter/durable_model/store.rb`
2. `packages/igniter-durable-model/spec/igniter/companion/store_spec.rb`
3. `packages/igniter-durable-model/spec/igniter/durable_model_spec.rb`
4. `packages/igniter-ledger-client/lib/igniter/ledger_client/client.rb`
5. `packages/igniter-ledger-client/lib/igniter/ledger_client/results.rb`
6. `packages/igniter-ledger-client/spec/igniter/ledger_client/client_spec.rb`
7. `packages/igniter-ledger/lib/igniter/store/protocol/interpreter.rb`
8. `packages/igniter-ledger/lib/igniter/store/protocol/wire_envelope.rb`
9. `packages/igniter-ledger/spec/igniter/store/protocol/op*_spec.rb`
10. `packages/igniter-ledger/lib/igniter/store/igniter_store.rb`

Do not read the whole repository. This is a replay filter / Durable Model
client parity slice.

## Acceptance

Done means:

- Protocol replay supports `filter[:store] + filter[:key]`.
- Protocol replay supports
  `filter[:store] + filter[:partition_key] + filter[:partition_value]`.
- Ledger Client exposes convenience args for key and partition replay filters.
- Existing `client.replay(store:)` behavior remains compatible.
- Client-backed Durable Model `replay(history_class, partition:)` works.
- Client-backed Durable Model `replay(..., partition:, since:, as_of:)` works.
- Embedded Durable Model replay behavior is unchanged.
- Docs list partition replay as supported for client-backed mode.
- Remaining unsupported client-backed features still fail clearly.

Required tests:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec
```

If full Ledger suite is too expensive for the current turn, at minimum run the
Ledger protocol specs touched by replay and clearly report the narrower scope.

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-durable-model/client-history-partition-replay-v0
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

- Ledger protocol `replay` now supports `filter[:store] + filter[:key]` and
  `filter[:store] + filter[:partition_key] + filter[:partition_value]`.
- Ledger Client now exposes replay convenience arguments for key and partition
  filters while preserving explicit `filter:`.
- Client-backed Durable Model now supports `replay(history_class, partition:)`
  with `since:` / `as_of:` boundaries.
