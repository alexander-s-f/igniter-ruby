# Track: Durable Model Command Operation Plan v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Command intent boundary is now closed:

- `Record.command` declares metadata.
- `_effects` derives persistence effect metadata.
- Ledger sees command/effect descriptors.
- `Store#command_intent` builds an immutable `CommandIntent`.
- `CommandIntent` is data, not action.
- `execution_allowed: false` prevents accidental command execution.

The next missing layer is a dry-run operation plan:

```text
CommandIntent -> CommandOperationPlan -> future app boundary apply/audit
```

This plan answers:

- What operation would the app boundary apply?
- Which store/history is targeted?
- Which key/event/value would be used?
- Is the intent currently valid?
- What would be written if a future explicit apply step existed?

It must not write facts.

## Goal

Add a pure command operation planning layer to Durable Model.

Desired shape:

```ruby
intent = store.command_intent(Reminder, :complete, key: "r1")
plan = store.command_operation_plan(intent)

plan.to_h
# => {
#      schema_version: 1,
#      kind: :command_operation_plan,
#      owner: :reminders,
#      command: :complete,
#      subject_key: "r1",
#      operation: :record_update,
#      status: :ready,
#      target: { shape: :store, name: :reminders, key: "r1" },
#      value: { title: "Buy milk", status: :done },
#      effect: { store_op: :store_write, write_kind: :update, lowers_to: :store_t },
#      errors: [],
#      warnings: [],
#      execution_allowed: false
#    }
```

This is a planning/preview object only. It should be useful for UI previews,
validation, audit receipts, Spark CRM workflows, and future app-boundary command
application.

## Required Shape

### 1. Add `CommandOperationPlan` value object

Add a small immutable class:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_operation_plan.rb
```

Suggested fields:

- `schema_version`
- `kind` (`:command_operation_plan`)
- `owner`
- `command`
- `subject_key`
- `operation`
- `status`
- `target`
- `value`
- `event`
- `effect`
- `errors`
- `warnings`
- `metadata`
- `execution_allowed`

Common behavior:

- named readers
- `ready?`
- `invalid?`
- `to_h`
- `[]`
- freeze
- normalize string keys to symbols where appropriate
- default `execution_allowed: false`

Do not depend on Ledger internals.

### 2. Add `Store#command_operation_plan`

Add:

```ruby
store.command_operation_plan(intent)
```

Behavior:

- accepts `Igniter::DurableModel::CommandIntent`
- validates the owner schema is registered if planning requires typed reads
- returns `CommandOperationPlan`
- may read current record state for `record_update`
- must not write, append, publish, call callbacks, or dispatch Ledger wire ops
- works in embedded and client-backed Store

### 3. Operation planning rules

#### `record_update`

Requirements:

- `intent.subject_key` is required
- owner schema should be registered
- current record should exist

Plan:

```ruby
target = { shape: :store, name: intent.owner, key: intent.subject_key }
value = current_record.to_h.merge(intent.changes).merge(intent.params.fetch(:changes, {}))
status = :ready
```

If current record is missing:

```ruby
status = :invalid
errors include { code: :record_not_found, ... }
value = nil
```

#### `record_append`

Requirements:

- owner schema should be registered
- key may be nil in v0, because the future app boundary may generate it

Plan:

```ruby
target = { shape: :store, name: intent.owner, key: intent.subject_key }
value = intent.changes.merge(intent.params.fetch(:attributes, {}))
status = :ready
```

Do not generate a key in this slice.

#### `history_append`

Requirements:

- target history may be specified by command metadata or event metadata if
  available
- if no explicit history is available, use `intent.owner` as a conservative
  v0 target and add a warning

Plan:

```ruby
target = { shape: :history, name: history_name, key: nil }
event = intent.event.merge(intent.params)
status = :ready
```

Keep this simple. The purpose is to expose planned shape, not to solve all
history routing.

#### `none`

Plan:

```ruby
target = { shape: :none }
status = :ready
value = nil
event = nil
```

### 4. Safety and naming

Do not add:

- `execute_command`
- `apply_command`
- `apply_command_intent`
- `commit_command`
- Ledger protocol op
- MCP command tool

This slice is explicitly planning only.

`execution_allowed: false` must remain part of the plan. If a future apply API
appears, it should be a separate track and should accept this plan explicitly.

### 5. Docs

Update:

- `packages/igniter-durable-model/README.md`
- `packages/igniter-durable-model/README.ru.md`
- `packages/igniter-durable-model/docs/manifest-glossary.md`

Clarify the four command layers:

```text
command descriptor metadata
-> CommandIntent
-> CommandOperationPlan
-> future app-boundary apply/audit
```

Ledger remains metadata-only. `CommandOperationPlan` belongs to Durable Model.

## Non-Goals

- No execution.
- No persistence of command plans.
- No audit history append.
- No app callback runner.
- No Saga/workflow runtime.
- No authorization/capability grants.
- No Ledger protocol changes.
- No MCP mutating tools.
- No key generation for `record_append`.

## Suggested Read Set

1. `packages/igniter-durable-model/lib/igniter/durable_model/command_intent.rb`
2. `packages/igniter-durable-model/lib/igniter/durable_model/store.rb`
3. `packages/igniter-durable-model/lib/igniter/durable_model/record.rb`
4. `packages/igniter-durable-model/lib/igniter/durable_model/history.rb`
5. `packages/igniter-durable-model/spec/igniter/companion/store_spec.rb`
6. `packages/igniter-durable-model/README.md`
7. `packages/igniter-durable-model/README.ru.md`
8. `packages/igniter-durable-model/docs/manifest-glossary.md`

Do not read the whole repository. This is a Durable Model command planning
value-object slice.

## Acceptance

Done means:

- `Igniter::DurableModel::CommandOperationPlan` exists.
- `CommandOperationPlan` is immutable and exposes readers, `ready?`, `invalid?`,
  `to_h`, and `[]`.
- `Store#command_operation_plan(intent)` works in embedded mode.
- `Store#command_operation_plan(intent)` works in client-backed mode.
- `record_update` plan reads current record and merges changes without writing.
- missing record for `record_update` returns `status: :invalid` and a clear
  error.
- `record_append` plan builds a value without generating a key.
- `history_append` plan builds an event and target shape.
- `none` plan is ready with no target mutation.
- every plan has `execution_allowed: false`.
- no write/append/fact is produced by planning.
- Docs describe descriptor vs intent vs operation plan vs future app boundary.

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
Track: igniter-durable-model/command-operation-plan-v0
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

- This is the dry-run bridge between command intent and future explicit
  app-boundary application.
- Keep planning useful, boring, and non-mutating.
- `CommandOperationPlan` is immutable, hash-readable, and carries
  `execution_allowed: false`.
- `Store#command_operation_plan` covers `record_update`, `record_append`,
  `history_append`, and `none` without producing facts.
