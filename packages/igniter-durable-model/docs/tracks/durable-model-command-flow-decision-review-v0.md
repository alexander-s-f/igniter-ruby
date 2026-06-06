# Track: Durable Model Command Flow Decision Review v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Durable Model now has explicit command-flow decision history:

```text
CommandFlowView
  -> pin_command_flow_view(...)
  -> CommandFlowViewPin
  -> append_command_flow_decision(...)
  -> CommandFlowDecision history
```

That gives applications an audit trail, but consumers still have to replay and
interpret raw decision entries themselves. The next useful package slice is a
compact app-safe review read model over persisted decisions.

This is the decision-history counterpart of command-flow monitors: it should
answer "what decisions have we made, what changed, what is risky, and what needs
attention?" without executing commands or mutating business records.

## Goal

Add a reusable read model that summarizes persisted command-flow decisions.

Desired usage:

```ruby
review = store.command_flow_decision_review(
  owner: :orders,
  view_name: :dispatch_assignment_health,
  since: Time.now.utc - 3600,
  rules: [
    { name: :blocked, metric: :status_count, status: :blocked, op: :>=, value: 1 },
    { name: :unknown_meaning, metric: :meaning_status_count, meaning_status: :unknown, op: :>=, value: 1 }
  ]
)

review.status       # => :ok / :warning / :critical
review.summary      # compact counts
review.findings     # rule hits / advisory observations
review.decisions    # filtered decision entries or compact item hashes
```

## Required Shape

### 1. Add `CommandFlowDecisionReview`

Add a focused value object, likely:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_flow_decision_review.rb
```

Suggested fields:

- `schema_version`
- `kind` (`:command_flow_decision_review`)
- `owner`
- `filters`
- `status`
- `meaning_status`
- `generated_at`
- `horizon`
- `summary`
- `findings`
- `decisions`
- `metadata`
- `store_fact_exposed`
- `value_hash_exposed`

Rules:

- freeze the object and nested data where practical
- expose `to_h` and `[]`
- no raw Ledger fact ids, value hashes, or causation internals
- preserve app-safe logical ids such as pin receipt ids
- expose `Igniter::Companion::CommandFlowDecisionReview` compatibility alias

### 2. Add `Store#command_flow_decision_review`

Add:

```ruby
store.command_flow_decision_review(owner:,
  view_name: nil,
  action: nil,
  actor: nil,
  status: nil,
  meaning_status: nil,
  receipt_id: nil,
  since: nil,
  as_of: nil,
  limit: nil,
  rules: [],
  metadata: {},
  history_class: Igniter::DurableModel::CommandFlowDecision)
```

Behavior:

- build on `command_flow_decisions(...)`
- apply the same filters and temporal window
- return `CommandFlowDecisionReview`
- do not append history
- do not mutate records
- do not execute commands
- do not append `CommandActivity`
- work for embedded and client-backed Stores through the existing replay path

### 3. Summary Metrics

At minimum, include:

- `total`
- `status_count`
- `meaning_status_count`
- `view_count`
- `action_count`
- `actor_count`
- `missing_capability_count`
- `error_count`
- `warning_count`
- `latest_generated_at`

Keep keys symbolic in Ruby. Keep the structure stable and compact.

### 4. Findings / Rules

Support simple app-local rules over summary metrics.

Suggested rule shape:

```ruby
{
  name: :blocked_decisions,
  metric: :status_count,
  status: :blocked,
  op: :>=,
  value: 1,
  severity: :warning
}
```

Supported v0 metrics:

- `:total`
- `:status_count`
- `:meaning_status_count`
- `:view_count`
- `:action_count`
- `:actor_count`
- `:missing_capability_count`
- `:error_count`
- `:warning_count`

Supported operators:

- `:>`
- `:>=`
- `:<`
- `:<=`
- `:==`

Findings should include:

- `name`
- `status`
- `severity`
- `metric`
- `expected`
- `actual`
- `message`

Review status should be derived from findings:

- no findings -> `:ok`
- warning findings -> `:warning`
- critical findings -> `:critical`

### 5. Identifier Alignment

Decision history currently stores the pin `receipt_id`. The receipt returned by
`append_command_flow_decision` also has an app-local `decision_receipt_id`.

During this slice, make the identity story explicit:

- either add `decision_receipt_id` to `CommandFlowDecision` and allow filtering
  by it, or document that v0 persisted identity is the pin `receipt_id`
- keep any identifier app-safe
- do not expose Ledger fact ids

Prefer adding `decision_receipt_id` if it is a small, backward-compatible field
addition in pre-v1.

## Non-Goals

- No automatic decision persistence.
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

- `CommandFlowDecisionReview` value object shape, freezing, `to_h`, `[]`
- empty review returns `:ok` and zeroed summary
- review over pinned and blocked decisions
- filters: view_name, action, actor, status, meaning_status, receipt_id
- temporal filters: since/as_of
- limit
- summary metrics
- rule findings for each supported metric family
- severity-derived review status
- malformed rule raises clear `ArgumentError`
- embedded Store path
- client-backed Store path
- review does not mutate records
- review does not append `CommandActivity`
- review does not append decision history
- no raw fact ids, raw value hashes, or causation internals are exposed
- compatibility alias under `Igniter::Companion`

Recommended package checks:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
```

## Acceptance

- `CommandFlowDecisionReview` exists.
- `Igniter::Companion::CommandFlowDecisionReview` alias exists.
- `Store#command_flow_decision_review(...)` exists.
- Review builds on persisted `CommandFlowDecision` history.
- Review exposes compact summary metrics and findings.
- Embedded and client-backed Stores both work.
- Review is read-only and app-safe.
- Identifier policy for `receipt_id` / `decision_receipt_id` is explicit.
- Docs/README mention decision reviews.
- Full durable-model package specs pass.

## Handoff Notes

Please keep this slice as an app-safe read model over explicit decision history:

- do not turn decisions into workflow execution
- do not introduce transport endpoints
- do not add Ledger protocol operations
- do not read the whole repository; this is a Durable Model read-model slice
- use existing command-flow monitor/review patterns where they fit

This slice should make persisted decisions operationally useful without changing
the command execution boundary.

## Final Notes

Implemented as a read-only review model over explicit decision history:

- Added `CommandFlowDecisionReview` with frozen app-safe serialization,
  summary metrics, findings, filters, horizon, and metadata.
- Added `Igniter::Companion::CommandFlowDecisionReview` compatibility alias.
- Added `Store#command_flow_decision_review`.
- Added `decision_receipt_id` to persisted `CommandFlowDecision` entries and to
  `Store#command_flow_decisions` filtering, making the v0 identity story
  explicit alongside the pin `receipt_id`.
- Review builds on `command_flow_decisions`, supports the same filters and
  temporal window, and does not append history, mutate records, execute
  commands, append command activity, or add Ledger protocol operations.
- Summary includes total, status/meaning/view/action/actor counts, missing
  capability count, error count, warning count, and latest decision timestamp.
- Rules support total/status/meaning/view/action/actor/missing/error/warning
  metrics with comparison operators and warning/critical status folding.
- Covered empty review, embedded and client-backed paths, filters, temporal
  windows, limit, summary metrics, rule findings, malformed rules, app-safe
  serialization, and compatibility alias.
