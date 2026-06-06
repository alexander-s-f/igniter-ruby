# Track: Durable Model Command Intent Boundary v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target packages: `packages/igniter-durable-model`, `packages/igniter-ledger`, `packages/igniter-ledger-client`

## Context

Command/effect descriptor parity is now closed:

- `Record.command` metadata exists in Durable Model.
- `Record._effects` derives persistence effect metadata.
- Durable Model registration mirrors both to Ledger descriptors.
- Ledger metadata exposes `commands` and `effects`.
- Ledger does not execute app commands.

The next missing layer is the object that crosses the app boundary:

```text
command metadata -> normalized CommandIntent -> app boundary applies or projects it
```

We need this before adding any command runner, Saga runner, UI action surface, or
Spark CRM workflow integration.

## Goal

Add a pure, non-executing command intent boundary to Durable Model.

Desired shape:

```ruby
intent = store.command_intent(Reminder, :complete,
  key: "r1",
  params: { completed_by: "user-1" }
)

intent.to_h
# => {
#      schema_version: 1,
#      kind: :command_intent,
#      owner: :reminders,
#      command: :complete,
#      subject_key: "r1",
#      operation: :record_update,
#      target_shape: :store,
#      effect: {
#        store_op: :store_write,
#        write_kind: :update,
#        lowers_to: :store_t
#      },
#      boundary: :app,
#      changes: { status: :done },
#      params: { completed_by: "user-1" },
#      execution_allowed: false
#    }
```

This object should be useful for:

- app-local receipt projection
- activity history events
- future workflow runners
- UI action previews
- validation/debugging
- Spark CRM lead/technician action monitoring

But it must not execute commands.

## Required Shape

### 1. Add `CommandIntent` value object

Add a small immutable class, likely:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_intent.rb
```

Suggested fields:

- `schema_version`
- `kind` (`:command_intent`)
- `owner`
- `command`
- `subject_key`
- `operation`
- `target_shape`
- `effect`
- `boundary`
- `changes`
- `event`
- `params`
- `metadata`
- `execution_allowed`

Common behavior:

- named readers
- `to_h`
- `[]` transitional hash-like access
- frozen object
- normalize string keys to symbols where appropriate
- default `schema_version: 1`
- default `kind: :command_intent`
- default `boundary: :app`
- default `execution_allowed: false`

Do not put Ledger classes in this file.

### 2. Add `Store#command_intent`

Add a read-only Durable Model API:

```ruby
store.command_intent(schema_class, command_name, key: nil, params: {}, metadata: {})
```

Behavior:

- require `schema_class._commands[command_name]`
- require matching `schema_class._effects[command_name]` or derive `:none`
- return `CommandIntent`
- do not write, append, publish, call app callbacks, or touch Ledger
- work the same in embedded and client-backed Store

Errors:

- unknown command raises clear `ArgumentError`
- unknown operation should still produce a `:none` effect only if current
  `_effects` does that; do not invent new operation vocabulary here

### 3. Intent shape rules

Map command/effect metadata into the intent:

```ruby
operation    = command_attrs[:operation] || :none
target_shape = command_attrs[:target_shape] || derived from operation
changes      = command_attrs[:changes] if present
event        = command_attrs[:event] if present
effect       = schema_class._effects[command_name]
boundary     = command_attrs[:boundary] || effect[:boundary] || :app
```

For `record_update`, `subject_key` should usually be required. For this v0,
prefer a clear validation error when `operation` is `:record_update` and `key`
is missing.

For `record_append`, key may be nil if the future app boundary will generate it,
but preserve the passed key when present.

For `history_append`, key may be nil; event/params should be enough to project
the intent.

### 4. Optional app-safe projection helper

If low churn, add a small helper:

```ruby
intent.to_activity_event
```

or a separate utility:

```ruby
Igniter::DurableModel::CommandIntentProjection.call(intent)
```

Only include app-safe fields:

- kind
- owner
- command
- subject_key
- operation
- boundary
- status: `:intended`

Do not expose fact ids or value hashes.

This is optional; `CommandIntent#to_h` is enough for acceptance.

### 5. Ledger relationship

No new Ledger protocol operation is required in this slice.

Ledger already stores command/effect descriptors. `CommandIntent` lives in
Durable Model because it is app-boundary behavior metadata, not storage engine
behavior.

Do not add:

- `execute_command`
- `apply_command`
- wire op `:command_intent`
- MCP mutating tool
- Ledger-side command runner

### 6. Docs

Update:

- `packages/igniter-durable-model/README.md`
- `packages/igniter-durable-model/README.ru.md`
- `packages/igniter-durable-model/docs/manifest-glossary.md`

Clarify:

- commands now have three layers:
  - descriptor metadata
  - pure `CommandIntent`
  - future app-boundary application/projection
- `CommandIntent` is not execution
- `execution_allowed: false` is intentional in v0
- Ledger remains metadata-only for commands/effects

## Non-Goals

- No command execution.
- No command runner.
- No app callbacks.
- No writes/appends from `command_intent`.
- No Ledger protocol operation.
- No MCP command tools.
- No authorization/capability grants.
- No Saga/workflow runtime.
- No UI action surface.

## Suggested Read Set

1. `packages/igniter-durable-model/lib/igniter/durable_model/record.rb`
2. `packages/igniter-durable-model/lib/igniter/durable_model/store.rb`
3. `packages/igniter-durable-model/lib/igniter/durable_model/receipts.rb`
4. `packages/igniter-durable-model/spec/igniter/companion/store_spec.rb`
5. `packages/igniter-durable-model/docs/manifest-glossary.md`
6. `packages/igniter-durable-model/README.md`
7. `packages/igniter-durable-model/README.ru.md`
8. `packages/igniter-ledger/docs/open-protocol.md` only to avoid contradicting
   command/effect metadata-only wording

Do not read the whole repository. This is a Durable Model command intent value
object slice.

## Acceptance

Done means:

- `Igniter::DurableModel::CommandIntent` exists.
- `CommandIntent` is immutable and exposes readers, `to_h`, and `[]`.
- `Store#command_intent` works in embedded mode.
- `Store#command_intent` works in client-backed mode.
- `record_update` command intent requires `key`.
- Unknown command raises clear `ArgumentError`.
- Intent includes command metadata, derived effect metadata, params, and
  `execution_allowed: false`.
- No write/append/fact is produced by `command_intent`.
- Existing command/effect descriptor metadata remains unchanged.
- Docs describe descriptor vs intent vs future application boundary.

Required tests:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec/igniter/store/protocol/op1_spec.rb packages/igniter-ledger/spec/igniter/store/schema_graph_spec.rb
```

Ledger tests should stay green because no Ledger runtime behavior changes are
expected.

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-durable-model/command-intent-boundary-v0
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

- This slice creates the missing middle object between command descriptors and
  future app-side application.
- Keep it boring and explicit: intent is data, not action.
- `CommandIntent` is immutable, hash-readable, and carries
  `execution_allowed: false`.
- `Store#command_intent` works in embedded and client-backed modes without
  touching Ledger or producing facts.
