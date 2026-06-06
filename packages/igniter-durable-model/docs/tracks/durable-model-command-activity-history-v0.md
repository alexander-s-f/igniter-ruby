# Track: Durable Model Command Activity History v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Command activity projection is now app-safe and non-persistent:

```text
command/effect descriptors
-> CommandIntent
-> CommandOperationPlan
-> CommandActivityEvent
-> future app-boundary apply/audit persistence
```

`CommandActivityEvent` intentionally omits facts, value hashes, and planned
record values. The next layer can persist that app-safe summary into a history
stream, but only through an explicit audit call.

This is still not command execution.

## Goal

Add explicit command activity audit persistence.

Desired shape:

```ruby
intent = store.command_intent(Reminder, :complete, key: "r1")
plan = store.command_operation_plan(intent)
event = store.command_activity_event(plan)

receipt = store.append_command_activity(event)

receipt.to_h
# => {
#      schema_version: 1,
#      kind: :command_activity_receipt,
#      status: :recorded,
#      history: :command_activity,
#      owner: :reminders,
#      command: :complete,
#      subject_key: "r1",
#      activity_status: :planned,
#      store_fact_exposed: false,
#      value_hash_exposed: false,
#      execution_allowed: false
#    }
```

This writes an audit history event, not the command effect. It must not update
the target record, append the planned business history, or execute callbacks.

## Required Shape

### 1. Add built-in `CommandActivity` History

Add a small built-in History class, likely:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_activity.rb
```

Suggested shape:

```ruby
class CommandActivity
  include Igniter::DurableModel::History

  history_name :command_activity
  partition_key :owner

  field :owner
  field :command
  field :subject_key
  field :operation
  field :status
  field :intent_status
  field :plan_status
  field :target, default: nil
  field :errors, default: []
  field :warnings, default: []
  field :metadata, default: {}
  field :store_fact_exposed, default: false
  field :value_hash_exposed, default: false
  field :execution_allowed, default: false
end
```

Expose compatibility alias:

```ruby
Igniter::Companion::CommandActivity
```

### 2. Add app-safe receipt

Add `CommandActivityReceipt` or equivalent.

Fields:

- `schema_version`
- `kind` (`:command_activity_receipt`)
- `status` (`:recorded`)
- `history`
- `owner`
- `command`
- `subject_key`
- `activity_status`
- `store_fact_exposed`
- `value_hash_exposed`
- `execution_allowed`

Behavior:

- readers
- `to_h`
- `[]`
- freeze if consistent with nearby value objects

Do not expose:

- raw append receipt
- fact id
- value hash
- causation

### 3. Add explicit append API

Add:

```ruby
store.append_command_activity(event, history_class: Igniter::DurableModel::CommandActivity)
```

Behavior:

- requires `event` to be a `CommandActivityEvent`
- registers `history_class` if needed
- appends `event.to_h` minus storage-internal fields if needed
- returns `CommandActivityReceipt`, not raw `AppendReceipt`
- works in embedded and client-backed Store

Important:

- This is explicit audit persistence.
- It must not be called automatically by `command_intent`,
  `command_operation_plan`, or `command_activity_event`.
- It must not execute the planned command operation.

### 4. Replay shape

A caller should be able to replay audit history:

```ruby
events = store.replay(Igniter::DurableModel::CommandActivity,
  partition: :reminders
)
```

Acceptance should verify that replay returns typed `CommandActivity` events and
that partition replay works when supported.

### 5. Safety

Do not add:

- `apply_command`
- `execute_command`
- automatic audit recording
- target record writes
- business history appends
- Ledger protocol op
- MCP tool
- exposure of fact ids/value hashes through `CommandActivityReceipt`

### 6. Docs

Update:

- `packages/igniter-durable-model/README.md`
- `packages/igniter-durable-model/README.ru.md`
- `packages/igniter-durable-model/docs/manifest-glossary.md`

Clarify the six layers:

```text
command descriptor metadata
-> CommandIntent
-> CommandOperationPlan
-> CommandActivityEvent
-> explicit CommandActivity history append
-> future app-boundary command apply
```

The audit append is explicit and app-safe; it does not apply the command.

## Non-Goals

- No command execution.
- No automatic audit persistence.
- No target record mutation.
- No business history mutation from the plan.
- No Ledger protocol changes.
- No MCP tools.
- No fact id / value hash exposure in the app-safe receipt.
- No authorization/capability grants.

## Suggested Read Set

1. `packages/igniter-durable-model/lib/igniter/durable_model/command_activity_event.rb`
2. `packages/igniter-durable-model/lib/igniter/durable_model/command_operation_plan.rb`
3. `packages/igniter-durable-model/lib/igniter/durable_model/history.rb`
4. `packages/igniter-durable-model/lib/igniter/durable_model/receipts.rb`
5. `packages/igniter-durable-model/lib/igniter/durable_model/store.rb`
6. `packages/igniter-durable-model/spec/igniter/companion/store_spec.rb`
7. `packages/igniter-durable-model/README.md`
8. `packages/igniter-durable-model/README.ru.md`
9. `packages/igniter-durable-model/docs/manifest-glossary.md`

Do not read the whole repository. This is a Durable Model audit-history slice.

## Acceptance

Done means:

- `Igniter::DurableModel::CommandActivity` History exists.
- `Igniter::DurableModel::CommandActivityReceipt` or equivalent app-safe receipt
  exists.
- `Store#append_command_activity(event)` explicitly appends a
  `CommandActivityEvent`.
- It works in embedded Store.
- It works in client-backed Store.
- Replay returns typed `CommandActivity` events.
- Partition replay by owner works.
- Receipt exposes no fact id, no value hash, no causation.
- Target record is not mutated.
- Planned business history is not appended.
- No automatic audit append is introduced.
- Docs describe explicit audit persistence as separate from command apply.

Required tests:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec/igniter/store/protocol/op1_spec.rb packages/igniter-ledger/spec/igniter/store/schema_graph_spec.rb
```

Ledger tests should stay green because no Ledger behavior changes are expected.

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-durable-model/command-activity-history-v0
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

- This is the first explicit persistence step after app-safe projection.
- Keep the receipt app-safe and the operation non-executing.
- `CommandActivity` is a built-in History partitioned by owner.
- `Store#append_command_activity` records only app-safe audit summaries and
  returns `CommandActivityReceipt` without exposing fact ids/value hashes.
