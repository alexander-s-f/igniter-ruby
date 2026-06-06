# Track: Durable Model Command Lifecycle v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Durable Model now has a mature explicit command pipeline:

```text
command/effect descriptor metadata
-> CommandIntent
-> CommandOperationPlan
-> CommandActivityEvent
-> explicit CommandActivity history append
-> CommandPolicyDecision
-> explicit Store#apply_command
```

Each object is app-safe and intentionally avoids Ledger-side command execution.
However, application code currently has to manually stitch the command story
together across several objects and history replay calls.

The next slice should add a command lifecycle read model: a compact,
UI/agent-friendly status projection over the existing command pipeline.

## Goal

Add an app-safe lifecycle model for one command attempt.

Desired usage:

```ruby
intent = store.command_intent(Reminder, :complete, key: "r1",
  metadata: { request_id: "req-1" })
plan = store.command_operation_plan(intent)
policy = store.command_policy_decision(plan,
  actor: "user-1",
  capabilities: [:reminder_complete])
receipt = store.apply_command(plan,
  policy_decision: policy,
  audit: true)

lifecycle = store.command_lifecycle(
  owner: :reminders,
  command: :complete,
  subject_key: "r1",
  request_id: "req-1"
)

lifecycle.status # => :applied
lifecycle.to_h   # app-safe summary for UI/agents
```

This is a read/projection layer. It should not apply commands, mutate records,
evaluate policy, or add Ledger protocol operations.

## Required Shape

### 1. Add `CommandLifecycle`

Add a value object, likely:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_lifecycle.rb
```

Suggested fields:

- `schema_version`
- `kind` (`:command_lifecycle`)
- `status`
- `owner`
- `command`
- `subject_key`
- `request_id`
- `actor`
- `operation`
- `target`
- `intent_status`
- `plan_status`
- `policy_status`
- `apply_status`
- `activity_statuses`
- `errors`
- `warnings`
- `metadata`
- `latest_activity`
- `execution_boundary` (`:app`)
- `store_fact_exposed`
- `value_hash_exposed`

Suggested statuses:

- `:unknown`
- `:intended`
- `:planned`
- `:policy_denied`
- `:review_required`
- `:rejected`
- `:applied`

Behavior:

- readers
- status helpers where useful (`applied?`, `rejected?`, `review_required?`)
- `to_h`
- `[]`
- freeze if consistent with nearby objects

Do not expose fact ids, value hashes, causation, raw apply receipts, raw policy
provider payloads, or planned record values.

Expose compatibility alias:

```ruby
Igniter::Companion::CommandLifecycle
```

### 2. Add lifecycle projection API

Add:

```ruby
store.command_lifecycle(owner:, command:, subject_key: nil,
  request_id: nil,
  history_class: Igniter::DurableModel::CommandActivity)
```

Behavior:

- reads `CommandActivity` history only
- filters by `owner`
- filters by `command`
- filters by `subject_key` when given
- filters by `metadata[:request_id]` when given
- returns a `CommandLifecycle`
- returns `status: :unknown` when no matching activity exists
- uses the most recent matching activity as `latest_activity`
- aggregates errors/warnings from matching activity entries
- does not mutate storage

Important: this API should be useful even if app code did not keep local Ruby
objects for intent/plan/policy/receipt.

### 3. Add lifecycle event helper

Current `CommandActivity` history records activity events. Ensure lifecycle can
distinguish statuses produced by:

- intent/activity projection (`:intended`, `:planned`, `:rejected`)
- policy rejected apply (`:rejected` plus policy errors)
- applied apply (`:applied`)

If needed, add small metadata conventions when recording apply activity:

```ruby
metadata: {
  request_id: "...",
  actor: "...",
  lifecycle_stage: :apply
}
```

Do not require a migration or change old event shape in a breaking way.

### 4. Add optional timeline API

If it stays compact, add:

```ruby
store.command_lifecycle_events(owner:, command: nil, subject_key: nil,
  request_id: nil,
  history_class: Igniter::DurableModel::CommandActivity)
```

Returns typed `CommandActivity` events filtered in app code.

This is useful for UI/agents that want the full timeline rather than the
collapsed lifecycle.

### 5. Client-backed support

Lifecycle projection must work with:

- embedded Store
- client-backed Store

Use existing:

- `replay(CommandActivity, partition: owner)`
- Durable Model client replay filtering where available

Do not add Ledger protocol operations.

## Status Folding Rules

Use explicit deterministic folding rules.

Suggested precedence, from strongest to weakest:

```text
any latest applied activity        -> :applied
latest rejected with review error  -> :review_required
latest rejected with policy error  -> :policy_denied
latest rejected                    -> :rejected
latest planned                     -> :planned
latest intended                    -> :intended
no events                          -> :unknown
```

Keep this documented and covered by tests.

## Docs

Update:

- `packages/igniter-durable-model/README.md`
- `packages/igniter-durable-model/README.ru.md`
- `packages/igniter-durable-model/docs/manifest-glossary.md`

Clarify the command stack as:

```text
descriptor metadata
-> intent
-> plan
-> activity history
-> policy decision
-> explicit apply
-> lifecycle read model
```

Lifecycle is a read model, not an executor.

## Non-Goals

- No command execution.
- No policy evaluation beyond reading existing activity records.
- No automatic command lifecycle recording beyond existing explicit audit/apply
  activity.
- No Ledger protocol operation.
- No MCP tool.
- No server endpoint.
- No durable workflow engine.
- No global command table.
- No exposure of raw Ledger fact ids/value hashes.
- No attempt to solve distributed transaction sagas.

## Suggested Read Set

1. `packages/igniter-durable-model/lib/igniter/durable_model/command_activity.rb`
2. `packages/igniter-durable-model/lib/igniter/durable_model/command_activity_event.rb`
3. `packages/igniter-durable-model/lib/igniter/durable_model/command_policy_decision.rb`
4. `packages/igniter-durable-model/lib/igniter/durable_model/receipts.rb`
5. `packages/igniter-durable-model/lib/igniter/durable_model/store.rb`
6. `packages/igniter-durable-model/spec/igniter/companion/store_spec.rb`
7. `packages/igniter-durable-model/README.md`
8. `packages/igniter-durable-model/README.ru.md`
9. `packages/igniter-durable-model/docs/manifest-glossary.md`

Do not read the whole repository. This is a Durable Model command lifecycle
read-model slice.

## Acceptance

Done means:

- `CommandLifecycle` exists.
- `Igniter::Companion::CommandLifecycle` compatibility alias exists.
- `Store#command_lifecycle(...)` returns app-safe lifecycle summary.
- `Store#command_lifecycle(...)` supports embedded Store.
- `Store#command_lifecycle(...)` supports client-backed Store.
- unknown lifecycle returns `status: :unknown`.
- planned lifecycle folds to `:planned`.
- policy denial folds to `:policy_denied`.
- review requirement folds to `:review_required`.
- rejected apply folds to `:rejected`.
- applied command folds to `:applied`.
- lifecycle aggregates errors/warnings safely.
- optional `command_lifecycle_events` exists if compact.
- no Ledger protocol/MCP/server changes are introduced.
- docs describe lifecycle as read model, not executor.

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
Track: igniter-durable-model/command-lifecycle-v0
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

- `CommandLifecycle` is an app-safe read model over `CommandActivity` history,
  not an executor or workflow engine.
- `Store#command_lifecycle_events` returns the typed filtered activity timeline;
  `Store#command_lifecycle` folds that timeline into a compact status summary.
- Apply-created audit activity now carries `metadata[:lifecycle_stage] = :apply`
  and policy actor/status when a policy decision is present.
- Folding is deterministic: latest applied wins, then review-required rejected,
  policy-denied rejected, generic rejected, planned, intended, and finally
  unknown.
