# Track: Durable Model Command Flow v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Durable Model now has the individual pieces for an explicit command pipeline:

```text
descriptor metadata
-> CommandIntent
-> CommandOperationPlan
-> CommandActivityEvent
-> CommandActivity history
-> CommandPolicyDecision
-> Store#apply_command
-> CommandLifecycle
```

This is powerful, but application code must still stitch many calls together.
The next slice should add a transparent app-owned command flow object that
orchestrates the existing pieces without hiding mutation semantics.

This must not become a workflow engine or a Ledger-side executor.

## Goal

Add a high-level, app-safe command flow API with preview as the default and
explicit apply as an opt-in mode.

Desired usage:

```ruby
flow = store.command_flow(Reminder, :complete,
  key: "r1",
  actor: "user-1",
  capabilities: [:reminder_complete],
  metadata: { request_id: "req-1" },
  mode: :preview
)

flow.status       # => :planned
flow.applied?     # => false
flow.lifecycle    # => CommandLifecycle
flow.to_h         # app-safe complete command story

applied = store.command_flow(Reminder, :complete,
  key: "r1",
  actor: "user-1",
  capabilities: [:reminder_complete],
  metadata: { request_id: "req-2" },
  mode: :apply,
  audit: true
)

applied.status    # => :applied
```

## Required Shape

### 1. Add `CommandFlow`

Add a value object, likely:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_flow.rb
```

Suggested fields:

- `schema_version`
- `kind` (`:command_flow`)
- `status`
- `mode`
- `owner`
- `command`
- `subject_key`
- `request_id`
- `actor`
- `intent`
- `plan`
- `activity_event`
- `policy_decision`
- `apply_receipt`
- `lifecycle`
- `errors`
- `warnings`
- `metadata`
- `execution_boundary` (`:app`)
- `store_fact_exposed`
- `value_hash_exposed`

Suggested status folding:

- `:intended`
- `:planned`
- `:policy_denied`
- `:review_required`
- `:rejected`
- `:applied`

Behavior:

- readers
- `applied?`
- `rejected?`
- `review_required?`
- `to_h`
- `[]`
- freeze if consistent with nearby value objects

Do not expose raw Ledger fact ids, value hashes, causation, raw app secrets, or
raw provider payloads.

Expose compatibility alias:

```ruby
Igniter::Companion::CommandFlow
```

### 2. Add `Store#command_flow`

Add:

```ruby
store.command_flow(schema_class, command_name,
  key: nil,
  params: {},
  metadata: {},
  actor: nil,
  capabilities: [],
  approvals: [],
  policy: nil,
  mode: :preview,
  audit: false,
  history_class: nil,
  activity_history_class: Igniter::DurableModel::CommandActivity)
```

Behavior:

- builds `CommandIntent`
- builds `CommandOperationPlan`
- builds app-safe `CommandActivityEvent`
- builds `CommandPolicyDecision`
- in `mode: :preview`, does not call `apply_command`
- in `mode: :apply`, calls `apply_command` with the policy decision
- when `audit: true`, records useful activity history:
  - preview mode should record planned/rejected activity only if explicitly
    requested by `audit: true`
  - apply mode relies on `apply_command(..., audit: true)` for applied/rejected
    apply activity
- returns `CommandFlow`
- no mutation in `mode: :preview`
- no Ledger protocol operations

Accepted modes:

- `:preview`
- `:apply`

Unknown mode should raise `ArgumentError`.

### 3. Request identity

Ensure a request id exists in flow metadata.

Rules:

- If `metadata[:request_id]` is present, preserve it.
- If absent, generate a compact app-local request id.
- The request id should flow into intent metadata and lifecycle queries.

Do not use Ledger fact ids as request ids.

### 4. Flow lifecycle integration

`CommandFlow#lifecycle` should be a `CommandLifecycle`.

In preview mode:

- lifecycle may be derived from the just-built activity event if no audit was
  recorded, or from history if audit was recorded.
- document which behavior was chosen.

In apply mode:

- lifecycle should reflect the persisted apply activity when `audit: true`.
- if `audit: false`, lifecycle may be a non-persisted summary derived from
  current flow objects.

Keep the model deterministic and app-safe.

### 5. Client-backed support

The same API must work for embedded and client-backed Stores.

Use existing APIs:

- `command_intent`
- `command_operation_plan`
- `command_activity_event`
- `append_command_activity`
- `command_policy_decision`
- `apply_command`
- `command_lifecycle`

Do not add Ledger protocol operations.

## Non-Goals

- No Ledger-side command execution.
- No workflow engine.
- No saga engine.
- No automatic retries.
- No server endpoint.
- No MCP tool.
- No full authorization framework.
- No callbacks.
- No hidden apply in preview mode.
- No global command table.

## Suggested Read Set

1. `packages/igniter-durable-model/lib/igniter/durable_model/command_intent.rb`
2. `packages/igniter-durable-model/lib/igniter/durable_model/command_operation_plan.rb`
3. `packages/igniter-durable-model/lib/igniter/durable_model/command_activity_event.rb`
4. `packages/igniter-durable-model/lib/igniter/durable_model/command_policy_decision.rb`
5. `packages/igniter-durable-model/lib/igniter/durable_model/command_lifecycle.rb`
6. `packages/igniter-durable-model/lib/igniter/durable_model/store.rb`
7. `packages/igniter-durable-model/spec/igniter/companion/store_spec.rb`
8. `packages/igniter-durable-model/README.md`
9. `packages/igniter-durable-model/README.ru.md`
10. `packages/igniter-durable-model/docs/manifest-glossary.md`

Do not read the whole repository. This is a Durable Model command-flow slice.

## Acceptance

Done means:

- `CommandFlow` exists.
- `Igniter::Companion::CommandFlow` compatibility alias exists.
- `Store#command_flow(...)` exists.
- preview mode builds intent/plan/activity/policy/lifecycle without mutation.
- apply mode applies only when policy is allowed.
- policy denial returns flow status `:policy_denied` and does not mutate.
- review requirement returns flow status `:review_required` and does not mutate.
- invalid plans return flow status `:rejected` and do not mutate.
- request id is preserved or generated.
- embedded Store and client-backed Store both work.
- flow `to_h` is app-safe and does not expose fact ids/value hashes/causation.
- docs describe flow as transparent app-owned orchestration, not hidden
  execution or workflow engine.

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
Track: igniter-durable-model/command-flow-v0
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

- `CommandFlow` is an app-safe orchestration summary, not a workflow engine or
  Ledger-side executor.
- `Store#command_flow` defaults to `mode: :preview`; mutation only happens with
  explicit `mode: :apply`.
- Flow metadata preserves caller-provided `request_id` or generates compact
  app-local ids with `cmd_` prefix. These ids feed intent metadata and lifecycle
  queries.
- Preview lifecycle is derived from the in-memory activity event unless
  `audit: true` persists preview activity. Apply lifecycle is read from history
  when audited, otherwise derived from current flow objects.
