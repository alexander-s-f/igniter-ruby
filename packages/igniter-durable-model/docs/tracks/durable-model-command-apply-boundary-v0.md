# Track: Durable Model Command Apply Boundary v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Durable Model now has a command pipeline with clear non-execution layers:

```text
command/effect descriptor metadata
-> CommandIntent
-> CommandOperationPlan
-> CommandActivityEvent
-> explicit CommandActivity history append
-> future app-boundary command apply
```

The next slice is the first explicit application boundary. This must stay
application-owned. Ledger remains a storage/protocol engine and must not execute
app commands, callbacks, or behavior contracts.

## Goal

Add an explicit, opt-in `Store#apply_command` API that applies a ready
`CommandOperationPlan` through existing Durable Model write/append APIs.

Desired shape:

```ruby
intent = store.command_intent(Reminder, :complete, key: "r1")
plan = store.command_operation_plan(intent)

receipt = store.apply_command(plan, audit: true)

receipt.to_h
# => {
#      schema_version: 1,
#      kind: :command_apply_receipt,
#      status: :applied,
#      owner: :reminders,
#      command: :complete,
#      subject_key: "r1",
#      operation: :record_update,
#      target: { shape: :store, name: :reminders, key: "r1" },
#      mutation_intent: :record_write,
#      activity_recorded: true,
#      store_fact_exposed: false,
#      value_hash_exposed: false,
#      execution_boundary: :app
#    }
```

This is command application, but still not Ledger-side command execution.

## Required Shape

### 1. Add `CommandApplyReceipt`

Add an app-boundary receipt, likely in:

```text
packages/igniter-durable-model/lib/igniter/durable_model/receipts.rb
```

Fields:

- `schema_version`
- `kind` (`:command_apply_receipt`)
- `status` (`:applied` or `:rejected`)
- `owner`
- `command`
- `subject_key`
- `operation`
- `target`
- `mutation_intent`
- `activity_recorded`
- `store_fact_exposed`
- `value_hash_exposed`
- `execution_boundary` (`:app`)
- `errors`
- `warnings`

Behavior:

- readers
- `to_h`
- `[]`
- freeze if consistent with nearby value objects

Do not expose fact id, value hash, or causation in `to_h`.

### 2. Add explicit apply API

Add:

```ruby
store.apply_command(plan,
  key: nil,
  history_class: nil,
  audit: false,
  activity_history_class: Igniter::DurableModel::CommandActivity)
```

Behavior:

- requires `plan` to be `Igniter::DurableModel::CommandOperationPlan`
- rejects invalid/not-ready plans without mutation
- applies only supported operations
- returns `CommandApplyReceipt`
- optionally records app-safe command activity when `audit: true`

Supported operations for v0:

- `:record_update`
- `:record_append`
- `:history_append`
- `:none`

Operation semantics:

- `record_update`: require registered Record schema for `plan.owner`; require
  `plan.subject_key`; call existing `write(schema_class, key:, **plan.value)`.
- `record_append`: require registered Record schema for `plan.owner`; require
  explicit `key:` if `plan.subject_key` is nil; call existing `write`.
- `history_append`: require explicit `history_class:` or a registered History
  class matching `plan.target[:name]`; call existing `append`.
- `none`: return applied/no-op receipt without storage mutation.

### 3. Audit integration

When `audit: true`:

- derive a `CommandActivityEvent` from the plan
- use `status: :applied` after a successful mutation/no-op
- use `status: :rejected` for rejected plans
- call `append_command_activity`
- expose only `activity_recorded: true/false` in the apply receipt

Do not expose the raw `CommandActivityReceipt` through `CommandApplyReceipt#to_h`.

### 4. Client-backed support

The same API must work when `Store` is initialized with `client:`.

Use existing Durable Model APIs:

- `write`
- `append`
- `replay`
- `append_command_activity`

Do not add Ledger protocol operations.

### 5. Safety Rules

Do not add:

- Ledger-side command execution
- MCP command apply tool
- HTTP command apply endpoint
- automatic apply from `command_intent`
- automatic apply from `command_operation_plan`
- automatic apply from `command_activity_event`
- callbacks
- authorization/capability framework
- raw fact id/value hash exposure in `CommandApplyReceipt#to_h`

The plan object keeps `execution_allowed: false`; this means the plan itself is
not an authorization token. The explicit `Store#apply_command` call is the app
boundary.

## Docs

Update:

- `packages/igniter-durable-model/README.md`
- `packages/igniter-durable-model/README.ru.md`
- `packages/igniter-durable-model/docs/manifest-glossary.md`

Clarify the seven layers:

```text
command descriptor metadata
-> CommandIntent
-> CommandOperationPlan
-> CommandActivityEvent
-> explicit CommandActivity history append
-> explicit Store#apply_command
-> future policy/capability guarded application
```

## Non-Goals

- No policy/capability system yet.
- No command callbacks.
- No custom command Ruby block execution.
- No Ledger protocol op.
- No MCP tool.
- No server endpoint.
- No generated IDs for `record_append`; require explicit key in v0.
- No attempt to solve distributed transactions.

## Suggested Read Set

1. `packages/igniter-durable-model/lib/igniter/durable_model/store.rb`
2. `packages/igniter-durable-model/lib/igniter/durable_model/command_operation_plan.rb`
3. `packages/igniter-durable-model/lib/igniter/durable_model/command_activity_event.rb`
4. `packages/igniter-durable-model/lib/igniter/durable_model/command_activity.rb`
5. `packages/igniter-durable-model/lib/igniter/durable_model/receipts.rb`
6. `packages/igniter-durable-model/spec/igniter/companion/store_spec.rb`
7. `packages/igniter-durable-model/README.md`
8. `packages/igniter-durable-model/README.ru.md`
9. `packages/igniter-durable-model/docs/manifest-glossary.md`

Do not read the whole repository. This is a Durable Model app-boundary apply
slice.

## Acceptance

Done means:

- `CommandApplyReceipt` exists and is app-safe.
- `Store#apply_command(plan)` exists.
- `record_update` applies a ready plan.
- `record_append` applies a ready plan only with explicit key when needed.
- `history_append` applies a ready plan with explicit/resolved History class.
- `none` produces an applied no-op receipt.
- invalid plans are rejected without mutation.
- optional `audit: true` appends `CommandActivity` with applied/rejected status.
- embedded Store and client-backed Store both work.
- no automatic apply is introduced.
- no Ledger protocol/MCP/server changes are introduced.
- docs describe apply as app-boundary behavior, not Ledger execution.

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
Track: igniter-durable-model/command-apply-boundary-v0
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

- `Store#apply_command` applies ready plans through Durable Model `write` and
  `append`, never through Ledger-side command execution.
- `CommandApplyReceipt` is app-safe and omits fact ids, value hashes, causation,
  and raw activity receipts.
- Optional `audit: true` records applied/rejected `CommandActivity` without
  making audit persistence automatic.
- Policy/capability remains the next layer.
