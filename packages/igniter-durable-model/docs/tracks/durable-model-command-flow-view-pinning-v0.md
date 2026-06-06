# Track: Durable Model Command Flow View Pinning v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Durable Model now has reusable operational views:

```text
CommandFlow
-> CommandActivity
-> CommandLifecycle
-> CommandFlowSlice
-> CommandFlowMonitorResult
-> CommandFlowView
```

`CommandFlowView` can say when a view is live, when a pinned horizon is needed,
and whether an action is advisory-actionable. But the package still has no
explicit object for the next important step:

```text
live operational view
  -> pinned decision evidence
  -> optional future command/effect receipt
```

This slice should add explicit pinning as an app-owned read-model operation.
It should not execute commands or mutate business records.

## Goal

Add a way to pin a named command-flow operational view into reproducible
decision evidence.

Desired usage:

```ruby
view = store.command_flow_view(:dispatch_assignment_health)
view.pin_required? # => true

pin = store.pin_command_flow_view(:dispatch_assignment_health,
  action: :mutate,
  actor: "dispatcher-1",
  capabilities: [:dispatch_review],
  metadata: { request_id: "pin-1" }
)

pin.status          # => :pinned / :blocked
pin.meaning_status  # => :reproducible / :live / :unknown
pin.view            # => CommandFlowView with pinned horizon
pin.receipt         # => app-safe decision receipt hash/value object
pin.to_h            # serializable, no raw Ledger internals
```

The pin operation should create a reproducible decision artifact that agents
and humans can cite before approving, mutating, executing, or escalating.

## Required Shape

### 1. Add `CommandFlowViewPin`

Add a value object, likely:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_flow_view_pin.rb
```

Suggested fields:

- `schema_version`
- `kind` (`:command_flow_view_pin`)
- `status` (`:pinned`, `:blocked`)
- `meaning_status` (`:reproducible`, `:live`, `:provisional`, `:stale`, `:unknown`)
- `name`
- `owner`
- `action`
- `actor`
- `capabilities`
- `missing_capabilities`
- `horizon`
- `view`
- `receipt`
- `errors`
- `warnings`
- `metadata`
- `generated_at`
- `execution_boundary` (`:app`)
- `store_fact_exposed`
- `value_hash_exposed`

Behavior:

- readers
- `pinned?`
- `blocked?`
- `reproducible?`
- `[]`
- `to_h`
- frozen if consistent with nearby value objects

Expose compatibility alias:

```ruby
Igniter::Companion::CommandFlowViewPin
```

### 2. Add Pin Receipt Shape

Either add `CommandFlowViewPinReceipt` or keep a compact nested hash, but the
serialized receipt shape should be stable:

- `kind` (`:command_flow_view_pin_receipt`)
- `receipt_id`
- `view_name`
- `owner`
- `action`
- `actor`
- `status`
- `meaning_status`
- `horizon`
- `capabilities`
- `missing_capabilities`
- `view_status`
- `monitor_status`
- `summary`
- `generated_at`
- `metadata`

Rules:

- receipt id must be app-local, stable for this pin result, and not a Ledger
  fact id
- no raw values
- no raw fact ids
- no causation internals

### 3. Add `Store#pin_command_flow_view`

Add:

```ruby
store.pin_command_flow_view(name,
  action:,
  actor: nil,
  capabilities: [],
  since: nil,
  as_of: nil,
  limit: nil,
  overrides: {},
  metadata: {},
  history_class: Igniter::DurableModel::CommandActivity)
```

Behavior:

- lookup the registered operational view
- build a pinned horizon:
  - if `as_of:` is supplied, use it
  - otherwise use current `Time.now.utc`
  - set `mode: :reproducible`
  - preserve descriptor `rule_version` if present, otherwise set a conservative
    explicit value such as `:current_rules`
  - preserve or synthesize bounded `fact_scope`
- evaluate `command_flow_view(...)` using the pinned `as_of`
- check `view.actionable?(action, capabilities:)`
- return `CommandFlowViewPin`
- do not mutate business records
- do not execute commands
- do not append command activity
- do not add Ledger protocol operations

Unknown view name should raise `ArgumentError`.
Unknown or forbidden action should return blocked pin evidence, not execute
anything.

### 4. Meaning Status

Use compact v0 semantics:

- `:reproducible` when horizon mode is reproducible and action is allowed
- `:live` when horizon remains live
- `:unknown` when the view cannot establish a bounded horizon/fact scope
- `:provisional` reserved for future runtime evidence gaps
- `:stale` reserved for future invalidation evidence

This is not the full Igniter-Lang bridge. It is the Durable Model local
read-model shape that can later lower into bridge observations.

### 5. Action Blocking

When action is not allowed:

- return `status: :blocked`
- include `errors` with structured codes, for example:
  - `:action_forbidden`
  - `:missing_capabilities`
  - `:pinned_horizon_required`
  - `:unknown_view_action`
- include `missing_capabilities` when relevant
- keep the evaluated view attached when available

Do not raise for policy/action blocks unless the view itself is missing or the
API input is malformed.

## Non-Goals

- No business record mutation.
- No command execution.
- No scheduler.
- No notification delivery.
- No HTTP endpoint.
- No MCP tool.
- No Ledger protocol operation.
- No observation envelope bridge implementation.
- No durable pin registry.
- No automatic audit append.

## Tests

Add focused specs covering:

- `CommandFlowViewPin` value object shape, freezing, helpers, `to_h`, `[]`
- receipt shape and app-safe serialization
- pinning a live view produces reproducible pinned evidence
- pinning with explicit `as_of`
- pinning with generated app-local receipt id
- blocked action for forbidden policy
- blocked action for missing capabilities
- `missing_capabilities`
- embedded Store pin over real command-flow history
- client-backed Store pin over real command-flow history
- unknown view raises clear `ArgumentError`
- no mutation happens during pinning
- no command activity is appended by pinning
- no raw fact ids, raw values, or causation internals are exposed
- compatibility alias under `Igniter::Companion`

Recommended package checks:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
```

## Acceptance

- `CommandFlowViewPin` exists.
- `Igniter::Companion::CommandFlowViewPin` compatibility alias exists.
- `Store#pin_command_flow_view(...)` exists.
- Embedded and client-backed Stores both work.
- Pinning returns explicit pinned/blocked evidence.
- Pinning does not mutate records, execute commands, append command activity,
  or add Ledger protocol operations.
- Docs/README mention view pinning.
- Full durable-model package specs pass.

## Handoff Notes

Please keep this slice narrow:

- build on `CommandFlowView`
- treat pinning as decision evidence, not command execution
- keep receipt app-safe and local
- do not introduce durable pin storage yet
- keep Ledger Client as transport/history boundary only
- do not read the whole repository; this is a Durable Model view-pinning slice

This slice should turn "this view requires pinning" into an explicit object the
application, agent, or future bridge can carry forward.

## Final Notes

Implemented as an app-owned read-model pinning layer:

- Added `CommandFlowViewPin` with frozen app-safe serialization, helpers, and a
  stable nested receipt shape.
- Added `Igniter::Companion::CommandFlowViewPin` compatibility alias.
- Added `Store#pin_command_flow_view`.
- Pinning builds a reproducible horizon from the descriptor, supplied or current
  `as_of`, explicit rule version, and bounded command-activity fact scope.
- Pinning evaluates the named operational view with that pinned horizon and
  returns `:pinned` or `:blocked` decision evidence.
- Forbidden, unknown, and missing-capability actions return blocked evidence
  with structured error codes.
- Missing view names and missing action input raise `ArgumentError`.
- Covered embedded and client-backed stores, generated receipt ids, explicit
  `as_of`, no command activity append, app-safe serialization, blocked actions,
  missing capabilities, and the compatibility alias.
