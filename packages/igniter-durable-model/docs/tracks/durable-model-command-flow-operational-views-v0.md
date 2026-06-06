# Track: Durable Model Command Flow Operational Views v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Durable Model now has a command observation stack:

```text
CommandFlow
-> CommandActivity history
-> CommandLifecycle
-> CommandFlowSlice
-> CommandFlowMonitorResult
```

This stack can answer:

- what one command did
- what happened in a temporal command window
- whether a temporal command window crosses explicit monitor thresholds

The missing package-level shape is a **named operational view**: a reusable
application descriptor that binds a command-flow slice, monitor rules, temporal
horizon defaults, and action policy into one app-safe object.

This is the Durable Model counterpart to the Igniter-Lang named slice idea:

```text
NamedSlice = name + contract_ref + output_shape + horizon + action_policy
```

Do not implement Igniter-Lang. Do not add observation envelope bridge code. This
slice should stay inside Durable Model and continue using existing Ledger Client
read/history boundaries.

## Goal

Add reusable command-flow operational views.

Desired usage:

```ruby
store.register_command_flow_view(:dispatch_assignment_health,
  owner: :orders,
  command: :assign_technician,
  horizon: {
    mode: :live,
    as_of: :latest,
    rule_version: :latest,
    fact_scope: { history: :command_activity, owner: :orders }
  },
  action_policy: {
    inspect: true,
    suggest: true,
    mutate: :requires_pinned_horizon,
    required_capabilities: [:dispatch_review]
  },
  rules: [
    {
      name: :assignment_denial_rate,
      metric: :status_ratio,
      status: :policy_denied,
      op: :>,
      value: 0.2,
      severity: :warning
    }
  ])

view = store.command_flow_view(:dispatch_assignment_health,
  since: Time.now.utc - 3600
)

view.status           # => :ok / :warning / :critical
view.mode             # => :live / :reproducible
view.pin_required?    # => true for mutation-grade action from live horizon
view.slice            # => CommandFlowSlice
view.monitor          # => CommandFlowMonitorResult
view.to_h             # app-safe named operational report
```

## Required Shape

### 1. Add `CommandFlowViewDescriptor`

Add a value object, likely:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_flow_view_descriptor.rb
```

Suggested fields:

- `schema_version`
- `kind` (`:command_flow_view_descriptor`)
- `name`
- `owner`
- `filters`
- `horizon`
- `mode`
- `action_policy`
- `rules`
- `metadata`
- `execution_boundary` (`:app`)
- `store_fact_exposed`
- `value_hash_exposed`

Behavior:

- readers
- `live?`
- `reproducible?`
- `to_h`
- `[]`
- frozen if consistent with nearby value objects

Expose compatibility alias:

```ruby
Igniter::Companion::CommandFlowViewDescriptor
```

### 2. Add `CommandFlowView`

Add a value object, likely:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_flow_view.rb
```

Suggested fields:

- `schema_version`
- `kind` (`:command_flow_view`)
- `name`
- `owner`
- `status`
- `mode`
- `horizon`
- `filters`
- `action_policy`
- `slice`
- `monitor`
- `summary`
- `generated_at`
- `execution_boundary` (`:app`)
- `store_fact_exposed`
- `value_hash_exposed`

Behavior:

- readers
- `ok?`
- `warning?`
- `critical?`
- `live?`
- `reproducible?`
- `pin_required?`
- `actionable?(action, capabilities: [])`
- `to_h`
- `[]`
- frozen if consistent with nearby value objects

Expose compatibility alias:

```ruby
Igniter::Companion::CommandFlowView
```

`pin_required?` should be true when the view is live and the action policy says
mutation/execution/approval requires a pinned horizon.

### 3. Add Store Registry APIs

Add:

```ruby
store.register_command_flow_view(name,
  owner:,
  command: nil,
  subject_key: nil,
  request_id: nil,
  actor: nil,
  status: nil,
  horizon: {},
  action_policy: {},
  rules: [],
  metadata: {})
```

Add:

```ruby
store._command_flow_views
```

Return a compact descriptor snapshot keyed by name.

The registry is app-local Durable Model metadata. It may be mirrored in
`descriptor_snapshot` if this can be done without adding Ledger protocol
surface. Do not add a new Ledger descriptor kind in this slice unless the
existing descriptor path already accepts open metadata cleanly.

Client-backed stores may keep the view registry locally. Evaluation should
still use existing client-backed replay/history paths.

### 4. Add Evaluation API

Add:

```ruby
store.command_flow_view(name,
  since: nil,
  as_of: nil,
  limit: nil,
  overrides: {},
  history_class: Igniter::DurableModel::CommandActivity)
```

Behavior:

- lookup the registered descriptor
- merge descriptor filters with `overrides`
- build `CommandFlowSlice`
- evaluate `CommandFlowMonitorResult`
- return `CommandFlowView`
- do not mutate storage
- do not append command activity
- do not execute commands
- work in embedded and client-backed Stores

Unknown view name should raise `ArgumentError` with a clear message.

### 5. Horizon Semantics

Use a simple plain-data horizon hash in v0:

```ruby
{
  mode: :live | :reproducible,
  as_of: :latest | Time | nil,
  rule_version: :latest | String | Symbol | nil,
  fact_scope: Hash | Symbol | nil,
  replay_cursor: String | nil
}
```

Rules:

- default `mode` is `:live`
- fixed `as_of` + fixed `rule_version` + bounded `fact_scope` means
  reproducible unless explicitly declared otherwise
- `as_of: :latest` is live
- unknown mode raises `ArgumentError`
- do not over-formalize `ProjectionHorizon` in this package slice

This is a product/runtime descriptor, not the Igniter-Lang type itself.

### 6. Action Policy

Use a plain-data action policy:

```ruby
{
  inspect: true,
  suggest: true,
  approve: :requires_pinned_horizon,
  mutate: :requires_pinned_horizon,
  execute: :forbidden,
  required_capabilities: [:dispatch_review]
}
```

Accepted action decisions:

- `true`
- `false`
- `:forbidden`
- `:requires_pinned_horizon`
- `:requires_capability`

`CommandFlowView#actionable?(action, capabilities: [])` should interpret the
policy conservatively:

- forbidden/false => false
- true => true unless required capabilities are missing
- requires_capability => true only when required capabilities are present
- requires_pinned_horizon => true only when view is reproducible and
  capabilities are present

Keep this as a helper, not a security boundary. Real mutation still goes
through command policy/application APIs.

## Non-Goals

- No scheduler.
- No notification delivery.
- No durable monitor state.
- No HTTP endpoint.
- No MCP tool.
- No Ledger protocol operation.
- No Igniter-Lang runtime.
- No observation envelope bridge implementation.
- No automatic pin/receipt writing.
- No command execution from views.

## Tests

Add focused specs covering:

- `CommandFlowViewDescriptor` value object shape, freezing, `to_h`, helpers
- `CommandFlowView` value object shape, freezing, `to_h`, helpers
- `register_command_flow_view`
- `_command_flow_views`
- duplicate registration overwrites or is idempotent; document chosen behavior
- unknown view raises clear `ArgumentError`
- embedded Store evaluates a view over real command-flow history
- client-backed Store evaluates a view over real command-flow history
- descriptor filters + call-time overrides
- horizon mode: live vs reproducible
- `pin_required?`
- `actionable?` with allowed/forbidden/requires_pinned_horizon/requires_capability
- monitor status is reflected on view status
- serialization is app-safe: no raw fact ids, raw values, causation internals
- compatibility aliases under `Igniter::Companion`

Recommended package checks:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
```

## Acceptance

- `CommandFlowViewDescriptor` exists.
- `CommandFlowView` exists.
- `Igniter::Companion` compatibility aliases exist.
- `Store#register_command_flow_view(...)` exists.
- `Store#_command_flow_views` exists.
- `Store#command_flow_view(...)` exists.
- Embedded and client-backed Stores both work.
- View evaluation is deterministic over its selected temporal window.
- No mutation happens during view evaluation.
- No Ledger protocol operation is added.
- Docs/README mention operational views.
- Full durable-model package specs pass.

## Handoff Notes

Please keep this slice a package-level operational read model:

- build on `CommandFlowSlice`
- build on `CommandFlowMonitorResult`
- keep descriptors as plain app-safe data
- keep action policy advisory, not a security boundary
- keep Ledger Client as transport/history boundary only
- do not read the whole repository; this is a Durable Model command operational
  view slice

This slice should make the command observation stack reusable by applications
without turning Durable Model into a workflow engine or notification system.

## Final Notes

Implemented as an app-local Durable Model read-model layer:

- Added `CommandFlowViewDescriptor` and `CommandFlowView` value objects with
  frozen app-safe serialization, horizon helpers, pin checks, and advisory
  `actionable?` policy interpretation.
- Added `Igniter::Companion` compatibility aliases for both value objects.
- Added `Store#register_command_flow_view`, `Store#_command_flow_views`, and
  `Store#command_flow_view`.
- View registration overwrites duplicate names; unknown view lookup raises
  `ArgumentError`.
- View evaluation merges descriptor filters with call-time overrides, builds a
  `CommandFlowSlice`, evaluates `CommandFlowMonitorResult`, and returns a
  named report without mutation, audit append, command execution, scheduler,
  notification delivery, or Ledger protocol surface.
- Horizon mode defaults to `:live`; fixed `as_of`, fixed `rule_version`, and
  bounded `fact_scope` infer `:reproducible` unless explicitly declared.
- Covered embedded and client-backed stores, serialization safety, aliases,
  duplicate registration, overrides, horizon mode, `pin_required?`, and
  `actionable?`.
