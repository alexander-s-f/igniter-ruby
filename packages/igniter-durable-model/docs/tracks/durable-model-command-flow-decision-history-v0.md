# Track: Durable Model Command Flow Decision History v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Durable Model now has explicit operational view pinning:

```text
CommandFlowView
  -> pin_command_flow_view(...)
  -> CommandFlowViewPin
  -> command_flow_view_pin_receipt
```

Pinning is intentionally non-mutating and non-persistent. That was the correct
v0 boundary. The next useful slice is an explicit, app-owned decision history:
applications should be able to persist a pinned or blocked decision receipt only
when they ask for it, and later replay/query those decisions.

This should remain separate from `CommandActivity`. Command activity describes
command attempts. Decision history describes human/agent/app decisions made from
operational views.

## Goal

Add explicit persistence and replay for command-flow view pin decisions.

Desired usage:

```ruby
pin = store.pin_command_flow_view(:dispatch_assignment_health,
  action: :mutate,
  actor: "dispatcher-1",
  capabilities: [:dispatch_review])

receipt = store.append_command_flow_decision(pin)

decisions = store.command_flow_decisions(
  owner: :orders,
  view_name: :dispatch_assignment_health,
  action: :mutate,
  status: :pinned,
  actor: "dispatcher-1"
)
```

This gives applications an audit-grade trail of decisions without making pinning
itself mutate storage automatically.

## Required Shape

### 1. Add `CommandFlowDecision`

Add a built-in History schema, likely:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_flow_decision.rb
```

Suggested shape:

```ruby
class CommandFlowDecision
  include Igniter::DurableModel::History

  history_name :command_flow_decisions
  partition_key :owner

  field :owner
  field :view_name
  field :action
  field :actor, default: nil
  field :status
  field :meaning_status
  field :receipt_id
  field :horizon, default: {}
  field :capabilities, default: []
  field :missing_capabilities, default: []
  field :view_status, default: nil
  field :monitor_status, default: nil
  field :summary, default: {}
  field :errors, default: []
  field :warnings, default: []
  field :metadata, default: {}
  field :store_fact_exposed, default: false
  field :value_hash_exposed, default: false
end
```

Expose compatibility alias:

```ruby
Igniter::Companion::CommandFlowDecision
```

### 2. Add `CommandFlowDecisionReceipt`

Add an app-safe receipt value object, either in `receipts.rb` or a focused file.

Suggested fields:

- `schema_version`
- `kind` (`:command_flow_decision_receipt`)
- `status` (`:appended`, `:rejected`)
- `receipt_id`
- `decision_receipt_id`
- `owner`
- `view_name`
- `action`
- `actor`
- `meaning_status`
- `errors`
- `warnings`
- `metadata`
- `generated_at`
- `store_fact_exposed`
- `value_hash_exposed`

Rules:

- no raw Ledger fact id exposure
- no raw value hash exposure
- no causation internals
- receipt id should be app-local, not Ledger fact id

Expose compatibility alias:

```ruby
Igniter::Companion::CommandFlowDecisionReceipt
```

### 3. Add `Store#append_command_flow_decision`

Add:

```ruby
store.append_command_flow_decision(pin,
  history_class: Igniter::DurableModel::CommandFlowDecision,
  metadata: {})
```

Behavior:

- require `pin` to be a `CommandFlowViewPin`
- append one `CommandFlowDecision` history entry
- preserve both pinned and blocked decisions
- merge explicit metadata with pin metadata under app-safe rules
- return `CommandFlowDecisionReceipt`
- do not mutate business records
- do not execute commands
- do not append `CommandActivity`
- do not add Ledger protocol operations

Unknown/malformed pin should raise `ArgumentError`.

### 4. Add `Store#command_flow_decisions`

Add:

```ruby
store.command_flow_decisions(owner:,
  view_name: nil,
  action: nil,
  actor: nil,
  status: nil,
  meaning_status: nil,
  receipt_id: nil,
  since: nil,
  as_of: nil,
  limit: nil,
  history_class: Igniter::DurableModel::CommandFlowDecision)
```

Behavior:

- replay decision history by owner partition
- apply filters
- apply temporal window
- return typed `CommandFlowDecision` entries, or a compact read-model if one
  already fits existing local patterns better
- support embedded and client-backed Stores through existing history replay
- do not expose raw Ledger internals

### 5. Optional Summary Helper

If compact, add:

```ruby
store.command_flow_decision_summary(...)
```

This may return counts by `status`, `meaning_status`, `view_name`, `action`, and
`actor`. Only add if it is a thin wrapper around `command_flow_decisions`.

## Non-Goals

- No automatic persistence from `pin_command_flow_view`.
- No command execution.
- No business record mutation.
- No scheduler.
- No notification delivery.
- No HTTP endpoint.
- No MCP tool.
- No Ledger protocol operation.
- No observation envelope bridge implementation.
- No durable workflow engine.

## Tests

Add focused specs covering:

- `CommandFlowDecision` History schema shape and partition
- `CommandFlowDecisionReceipt` value object shape, freezing, `to_h`, `[]`
- append pinned decision
- append blocked decision
- app-safe receipt serialization
- malformed pin raises clear `ArgumentError`
- explicit metadata merge
- `command_flow_decisions` filters: view_name, action, actor, status,
  meaning_status, receipt_id
- temporal filters: since/as_of
- limit
- embedded Store path
- client-backed Store path
- append decision does not mutate business records
- append decision does not append `CommandActivity`
- no raw fact ids, raw value hashes, or causation internals are exposed
- compatibility aliases under `Igniter::Companion`

Recommended package checks:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
```

## Acceptance

- `CommandFlowDecision` exists.
- `CommandFlowDecisionReceipt` exists.
- `Igniter::Companion` compatibility aliases exist.
- `Store#append_command_flow_decision(...)` exists.
- `Store#command_flow_decisions(...)` exists.
- Embedded and client-backed Stores both work.
- Pinning remains non-persistent unless append is explicitly called.
- Decision append does not mutate records, execute commands, append command
  activity, or add Ledger protocol operations.
- Docs/README mention decision history.
- Full durable-model package specs pass.

## Handoff Notes

Please keep this slice as explicit audit persistence:

- build on `CommandFlowViewPin`
- keep decision history separate from command activity
- persist pinned and blocked decisions
- keep receipts app-safe and local
- do not introduce automatic append behavior
- keep Ledger Client as transport/history boundary only
- do not read the whole repository; this is a Durable Model decision-history
  slice

This slice should make operational decisions replayable without turning views,
pins, or decisions into a workflow engine.

## Final Notes

Implemented as explicit app-owned audit persistence:

- Added built-in `CommandFlowDecision` history with `history_name:
  :command_flow_decisions` and `partition_key :owner`.
- Added `CommandFlowDecisionReceipt` with app-safe serialization and app-local
  decision receipt ids.
- Added `Igniter::Companion` aliases for `CommandFlowDecision` and
  `CommandFlowDecisionReceipt`.
- Added `Store#append_command_flow_decision` for explicit persistence of pinned
  and blocked `CommandFlowViewPin` decisions.
- Added `Store#command_flow_decisions` for owner-partition replay with
  view/action/actor/status/meaning/receipt and temporal filters.
- Pinning remains non-persistent unless append is explicitly called.
- Decision history remains separate from `CommandActivity`; append does not
  mutate records, execute commands, append command activity, or add Ledger
  protocol operations.
- Covered embedded and client-backed stores, metadata merge, filters, temporal
  windows, limit, blocked decisions, malformed input, app-safe receipts, and
  compatibility aliases.
