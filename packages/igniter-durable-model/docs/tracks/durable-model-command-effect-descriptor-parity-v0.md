# Track: Durable Model Command / Effect Descriptor Parity v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target packages: `packages/igniter-durable-model`, `packages/igniter-ledger`, `packages/igniter-ledger-client`

## Context

Client-backed Durable Model now has good parity for durable shape and read-side
metadata:

- records and histories
- scopes and subscriptions
- partition replay
- relation descriptors and typed resolve
- projection descriptors
- read-only scatter snapshots
- provenance: `causation_chain`, `lineage`, `fact_ref`

The next gap is command/effect metadata.

`Igniter::DurableModel::Record` already has metadata-only command DSL:

```ruby
class Reminder
  include Igniter::DurableModel::Record
  store_name :reminders

  field :id
  field :title
  field :status, default: :open

  command :complete,
    operation: :record_update,
    changes: { status: :done }
end

Reminder._commands
Reminder._effects
```

But when a schema is registered through `Igniter::DurableModel::Store`, command
and effect metadata does not yet travel through the same Ledger descriptor /
metadata boundary as stores, histories, relations, and projections.

This matters because the architecture rule is:

```text
command -> normalized mutation_intent -> app boundary
```

Commands are graph-owned behavior contracts. Ledger should not execute them,
but Ledger metadata should be able to describe them.

## Goal

Make Durable Model command/effect metadata visible through the standard
Ledger metadata boundary.

Desired shape:

```ruby
store = Igniter::DurableModel::Store.new(client: ledger_client)
store.register(Reminder)

snap = store.metadata_snapshot
snap[:commands][:reminders][:complete]
# => {
#      name: :complete,
#      owner: :reminders,
#      operation: :record_update,
#      target_shape: :store,
#      boundary: :app,
#      mutation_intent: :record_update,
#      changes: { status: :done }
#    }

snap[:effects][:reminders][:complete]
# => {
#      name: :complete,
#      owner: :reminders,
#      store_op: :store_write,
#      write_kind: :update,
#      lowers_to: :store_t,
#      boundary: :app
#    }
```

## Required Shape

### 1. Ledger descriptor kinds

Add metadata-only protocol descriptor handlers for:

- `kind: :command`
- `kind: :effect`

Files likely involved:

- `packages/igniter-ledger/lib/igniter/store/protocol/interpreter.rb`
- `packages/igniter-ledger/lib/igniter/store/protocol/handlers/`
- `packages/igniter-ledger/lib/igniter/store/schema_graph.rb`

Descriptor examples:

```ruby
{
  schema_version: 1,
  kind: :command,
  name: :complete,
  owner: :reminders,
  operation: :record_update,
  target_shape: :store,
  boundary: :app,
  mutation_intent: :record_update,
  changes: { status: :done }
}

{
  schema_version: 1,
  kind: :effect,
  name: :complete,
  owner: :reminders,
  store_op: :store_write,
  write_kind: :update,
  lowers_to: :store_t,
  boundary: :app,
  source_operation: :record_update
}
```

Validation guidance:

- required command fields: `name`, `owner`, `operation`
- required effect fields: `name`, `owner`, `store_op`, `write_kind`
- default `boundary` to `:app`
- normalize `name`, `owner`, `operation`, `store_op`, `write_kind`,
  `target_shape`, `lowers_to`, and `boundary` to symbols
- accepted operations for command metadata:
  - `:record_append`
  - `:record_update`
  - `:history_append`
  - `:none`
- unknown operations should be accepted only with `effect: :none` / warning, or
  rejected clearly. Prefer clear rejection if it matches existing handler style.

These descriptors must be metadata-only. Do not execute commands inside Ledger.

### 2. SchemaGraph snapshots

Extend `SchemaGraph` with compact snapshots:

```ruby
schema_graph.command_snapshot
schema_graph.effect_snapshot
```

Suggested shape:

```ruby
{
  reminders: {
    complete: { name: :complete, owner: :reminders, ... }
  }
}
```

Add both to `Protocol::Interpreter#metadata_snapshot`:

```ruby
{
  commands: ...,
  effects: ...
}
```

Also include raw descriptor registries in `descriptor_snapshot` if that is the
established OP2 descriptor pattern.

Keep existing metadata keys stable.

### 3. Durable Model registration

When `Igniter::DurableModel::Store#register(schema_class)` sees a Record class
with `_commands` / `_effects`, it should emit command and effect descriptors via
the same `@inner.register_descriptor` path used for store/history/relation/
projection descriptors.

This must work in both modes:

- embedded Store
- client-backed Store

Mapping:

```ruby
schema_class._commands.each do |command_name, attrs|
  # emit kind: :command
end

schema_class._effects.each do |command_name, attrs|
  # emit kind: :effect
end
```

Guidance:

- `owner` should be `schema_class.store_name`
- `operation` should come from command attrs
- `mutation_intent` should preserve operation vocabulary
- derive `target_shape` from operation:
  - `record_append`, `record_update` -> `:store`
  - `history_append` -> `:history`
  - `none` / unknown -> `:none`
- preserve app boundary: `boundary: :app`
- do not add command execution methods in this slice
- do not allow Ledger to call app code

### 4. Durable Model manifest helpers

Do not add a broad new public API unless needed, but tests should prove that:

- `Reminder._commands` still works
- `Reminder._effects` still works
- `store.metadata_snapshot[:commands]` includes registered command descriptors
- `store.metadata_snapshot[:effects]` includes derived effect descriptors
- client-backed and embedded modes return compatible shapes

If a small helper is useful, prefer read-only names:

```ruby
store._commands
store._effects
```

But only add these if they mirror existing `_relations`, `_projections`,
`_scatters` style cleanly. Avoid adding execution vocabulary.

### 5. Ledger Client

No new explicit client method is required if commands/effects flow through
`register_descriptor` and `metadata_snapshot`.

Do update Ledger Client tests if `metadata_snapshot` fixtures or descriptor
validation need to include `commands` / `effects`.

### 6. Docs

Update:

- `packages/igniter-durable-model/README.md`
- `packages/igniter-durable-model/README.ru.md`
- `packages/igniter-durable-model/docs/manifest-glossary.md`
- `packages/igniter-ledger/docs/open-protocol.md`

Clarify:

- command/effect descriptors are metadata-only
- commands still lower to mutation intent
- side effects still happen at the app boundary
- Ledger stores descriptors but does not execute app commands

## Non-Goals

- No command execution.
- No app callback registry.
- No Saga runner.
- No workflow engine.
- No write authorization or capability grants.
- No graph runtime changes.
- No generated UI for commands.
- No DB migration or storage planner changes.

## Suggested Read Set

1. `packages/igniter-durable-model/lib/igniter/durable_model/record.rb`
2. `packages/igniter-durable-model/lib/igniter/durable_model/store.rb`
3. `packages/igniter-durable-model/spec/igniter/companion/store_spec.rb`
4. `packages/igniter-durable-model/docs/manifest-glossary.md`
5. `packages/igniter-ledger/lib/igniter/store/schema_graph.rb`
6. `packages/igniter-ledger/lib/igniter/store/protocol/interpreter.rb`
7. `packages/igniter-ledger/lib/igniter/store/protocol/handlers/store_handler.rb`
8. `packages/igniter-ledger/lib/igniter/store/protocol/handlers/derivation_handler.rb`
9. `packages/igniter-ledger/spec/igniter/store/protocol/op1_spec.rb`
10. `packages/igniter-ledger/spec/igniter/store/protocol/op3_spec.rb`
11. `packages/igniter-ledger/spec/igniter/store/schema_graph_spec.rb`
12. `packages/igniter-ledger-client/spec/igniter/ledger_client/client_spec.rb`

Do not read the whole repository. This is a command/effect metadata descriptor
slice, not a runtime execution slice.

## Acceptance

Done means:

- Ledger protocol accepts `kind: :command` descriptors.
- Ledger protocol accepts `kind: :effect` descriptors.
- Invalid command/effect descriptors reject clearly.
- `metadata_snapshot` includes `:commands` and `:effects`.
- Descriptor snapshots include command/effect registries if descriptor snapshots
  are the local raw descriptor source.
- Embedded Durable Model registration emits command/effect descriptors.
- Client-backed Durable Model registration emits command/effect descriptors.
- Embedded and client-backed metadata snapshots have compatible command/effect
  shapes.
- Existing Record `_commands` and `_effects` remain unchanged.
- No command execution path is introduced.
- Docs state clearly that command/effect descriptors are metadata-only and app
  boundary owned.

Required tests:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec
```

If the full Ledger suite is too expensive for the current turn, at minimum run:

```bash
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec \
  packages/igniter-ledger/spec/igniter/store/protocol/op1_spec.rb \
  packages/igniter-ledger/spec/igniter/store/protocol/op3_spec.rb \
  packages/igniter-ledger/spec/igniter/store/schema_graph_spec.rb
```

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-durable-model/command-effect-descriptor-parity-v0
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

- This gives the Durable Model graph behavior metadata the same transport-safe
  descriptor path as storage, relations, and projections.
- It keeps the important boundary intact: Ledger can inspect command/effect
  intent, but only the app/contract boundary can execute side effects.
- Ledger protocol now has metadata-only `:command` and `:effect` descriptor
  handlers with clear validation.
- Durable Model registration emits command/effect descriptors in embedded and
  client-backed modes; `_commands` and `_effects` expose read-only snapshots.
