# Track: Durable Model Command Activity Projection v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Command planning is now non-mutating and explicit:

```text
command/effect descriptors
-> CommandIntent
-> CommandOperationPlan
-> future app-boundary apply/audit
```

The next useful layer is an app-safe activity projection. We need a compact
event shape that can feed UI previews, audit histories, agent monitors, and
Spark CRM workflows without leaking Ledger internals or executing commands.

`CommandIntent#to_activity_event` exists, but it is intentionally tiny. This
slice should make the projection first-class and cover both intent and operation
plan states.

## Goal

Add a pure command activity projection layer.

Desired shape:

```ruby
intent = store.command_intent(Reminder, :complete, key: "r1")
plan = store.command_operation_plan(intent)

event = store.command_activity_event(plan)

event.to_h
# => {
#      schema_version: 1,
#      kind: :command_activity_event,
#      owner: :reminders,
#      command: :complete,
#      subject_key: "r1",
#      operation: :record_update,
#      status: :planned,
#      plan_status: :ready,
#      target: { shape: :store, name: :reminders, key: "r1" },
#      errors: [],
#      warnings: [],
#      store_fact_exposed: false,
#      value_hash_exposed: false,
#      execution_allowed: false
#    }
```

This event is data only. It should not append to a history stream yet.

## Required Shape

### 1. Add `CommandActivityEvent` value object

Add:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_activity_event.rb
```

Suggested fields:

- `schema_version`
- `kind` (`:command_activity_event`)
- `owner`
- `command`
- `subject_key`
- `operation`
- `status`
- `intent_status`
- `plan_status`
- `target`
- `errors`
- `warnings`
- `metadata`
- `store_fact_exposed`
- `value_hash_exposed`
- `execution_allowed`

Common behavior:

- named readers
- `to_h`
- `[]`
- freeze
- normalize string keys to symbols where appropriate
- default `store_fact_exposed: false`
- default `value_hash_exposed: false`
- default `execution_allowed: false`

Do not include `fact_id`, `value_hash`, or raw planned `value` by default.
Activity is an app-facing summary, not a storage receipt.

### 2. Add projection API

Add:

```ruby
store.command_activity_event(source, status: nil, metadata: {})
```

Where `source` may be:

- `CommandIntent`
- `CommandOperationPlan`

Behavior:

- for `CommandIntent`, status defaults to `:intended`
- for ready `CommandOperationPlan`, status defaults to `:planned`
- for invalid `CommandOperationPlan`, status defaults to `:rejected`
- merge source metadata with explicit `metadata`
- include errors/warnings from plan sources
- include target from plan sources
- never write, append, publish, call callbacks, or touch Ledger

### 3. Projection shape rules

From `CommandIntent`:

```ruby
{
  status: :intended,
  intent_status: :ready,
  plan_status: nil,
  target: nil,
  errors: [],
  warnings: []
}
```

From ready `CommandOperationPlan`:

```ruby
{
  status: :planned,
  intent_status: :ready,
  plan_status: :ready,
  target: plan.target,
  errors: [],
  warnings: plan.warnings
}
```

From invalid `CommandOperationPlan`:

```ruby
{
  status: :rejected,
  intent_status: :ready,
  plan_status: :invalid,
  target: plan.target,
  errors: plan.errors,
  warnings: plan.warnings
}
```

### 4. Optional History class

If low churn, add an example or helper class for future audit streams:

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
end
```

This must be documentation/example only in this slice. Do not auto-append
activity events.

### 5. Safety

Do not add:

- `append_command_activity`
- `record_command_activity`
- `apply_command`
- `execute_command`
- Ledger protocol op
- MCP tool
- automatic audit history writes

This slice is projection only.

### 6. Docs

Update:

- `packages/igniter-durable-model/README.md`
- `packages/igniter-durable-model/README.ru.md`
- `packages/igniter-durable-model/docs/manifest-glossary.md`

Clarify the five layers:

```text
command descriptor metadata
-> CommandIntent
-> CommandOperationPlan
-> CommandActivityEvent
-> future app-boundary apply/audit persistence
```

## Non-Goals

- No execution.
- No persistence.
- No automatic History append.
- No Ledger changes.
- No MCP tools.
- No receipt/fact exposure.
- No app callbacks.
- No Saga/workflow runtime.

## Suggested Read Set

1. `packages/igniter-durable-model/lib/igniter/durable_model/command_intent.rb`
2. `packages/igniter-durable-model/lib/igniter/durable_model/command_operation_plan.rb`
3. `packages/igniter-durable-model/lib/igniter/durable_model/store.rb`
4. `packages/igniter-durable-model/spec/igniter/companion/store_spec.rb`
5. `packages/igniter-durable-model/README.md`
6. `packages/igniter-durable-model/README.ru.md`
7. `packages/igniter-durable-model/docs/manifest-glossary.md`

Do not read the whole repository. This is a Durable Model projection value
object slice.

## Acceptance

Done means:

- `Igniter::DurableModel::CommandActivityEvent` exists.
- It is immutable and exposes readers, `to_h`, and `[]`.
- `Store#command_activity_event(intent)` returns an intended event.
- `Store#command_activity_event(plan)` returns planned/rejected events based on
  plan status.
- Event exposes no `fact_id`, no `value_hash`, and no planned record `value`.
- Event includes `store_fact_exposed: false`,
  `value_hash_exposed: false`, and `execution_allowed: false`.
- Works in embedded and client-backed Store.
- No write/append/fact is produced.
- Existing `CommandIntent#to_activity_event` remains compatible or delegates to
  the new shape if that is cleaner.
- Docs describe activity projection as non-persistent app-safe data.

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
Track: igniter-durable-model/command-activity-projection-v0
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

- This is the app-safe summary bridge after planning.
- Keep it projection-only. Persistence/application is a later explicit slice.
- `CommandActivityEvent` is immutable, hash-readable, and omits fact ids,
  value hashes, and planned record values.
- `Store#command_activity_event` covers `CommandIntent`, ready plans, and
  invalid plans without producing facts or audit history.
