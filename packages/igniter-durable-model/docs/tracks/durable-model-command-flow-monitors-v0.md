# Track: Durable Model Command Flow Monitors v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Durable Model now has a compact command observation stack:

```text
CommandFlow
-> CommandActivity history
-> CommandLifecycle
-> CommandFlowSlice
```

`CommandFlowSlice` answers "what happened in this temporal window?" The next
useful layer is an app-owned monitor over that slice: a deterministic,
serializable result that can say whether the command stream looks healthy,
requires review, or has crossed a domain threshold.

This should serve real application pressure:

- Spark CRM technician/order monitoring
- vendor lead signal monitoring
- telephony integration command health
- agent-readable daily/weekly operational summaries

Do not make this a scheduler, notification system, policy engine, or Ledger-side
runtime. It is a read-model evaluation layer over command-flow slices.

## Goal

Add command-flow monitor evaluation over `CommandFlowSlice`.

Desired usage:

```ruby
result = store.command_flow_monitor(
  owner: :orders,
  command: :assign_technician,
  since: Time.now.utc - 3600,
  rules: [
    {
      name: :too_many_rejections,
      metric: :status_count,
      status: :rejected,
      op: :>,
      value: 3,
      severity: :warning
    },
    {
      name: :review_backlog,
      metric: :status_count,
      status: :review_required,
      op: :>=,
      value: 1,
      severity: :critical
    },
    {
      name: :denial_rate,
      metric: :status_ratio,
      status: :policy_denied,
      op: :>,
      value: 0.2,
      severity: :warning
    }
  ]
)

result.status # => :ok / :warning / :critical
result.alerts # => app-safe triggered rule observations
result.to_h   # => serializable monitor report
```

## Required Shape

### 1. Add `CommandFlowMonitorResult`

Add a value object, likely:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_flow_monitor_result.rb
```

Suggested fields:

- `schema_version`
- `kind` (`:command_flow_monitor_result`)
- `name`
- `owner`
- `filters`
- `since`
- `as_of`
- `generated_at`
- `status`
- `rules`
- `observations`
- `alerts`
- `summary`
- `slice`
- `execution_boundary` (`:app`)
- `store_fact_exposed`
- `value_hash_exposed`

Behavior:

- readers
- `ok?`
- `warning?`
- `critical?`
- `triggered?`
- `[]`
- `to_h`
- freeze if consistent with nearby value objects

Expose compatibility alias:

```ruby
Igniter::Companion::CommandFlowMonitorResult
```

### 2. Add `Store#command_flow_monitor`

Add:

```ruby
store.command_flow_monitor(owner:,
  name: nil,
  command: nil,
  subject_key: nil,
  request_id: nil,
  actor: nil,
  status: nil,
  since: nil,
  as_of: nil,
  limit: nil,
  rules: [],
  slice: nil,
  history_class: Igniter::DurableModel::CommandActivity)
```

Behavior:

- if `slice:` is provided, evaluate that slice
- otherwise call `command_flow_slice(...)`
- evaluate all rules against the slice summary/items
- return `CommandFlowMonitorResult`
- work in embedded and client-backed Stores
- do not mutate storage
- do not append command activity
- do not call command application APIs
- do not add Ledger protocol operations

### 3. Rule Shape

Rules should be plain data hashes so agents and apps can generate them safely.

Required rule fields:

- `name`
- `metric`
- `op`
- `value`

Optional rule fields:

- `status`
- `command`
- `actor`
- `severity` (`:info`, `:warning`, `:critical`; default `:warning`)
- `message`
- `metadata`

Supported metrics for v0:

- `:total`
- `:status_count`
- `:status_ratio`
- `:command_count`
- `:actor_count`
- `:subject_count`
- `:request_count`

Supported operators for v0:

- `:>`
- `:>=`
- `:<`
- `:<=`
- `:==`
- `:!=`

Invalid metrics/operators should raise `ArgumentError` with a clear message.

### 4. Observation Shape

Each evaluated rule should produce an observation hash:

- `name`
- `metric`
- `op`
- `expected`
- `actual`
- `matched`
- `severity`
- `message`
- `metadata`

Triggered observations become `alerts`.

Do not expose raw Ledger facts, raw command values, causation internals, or raw
provider payloads.

### 5. Status Folding

Overall monitor result status:

- `:critical` if any critical alert matched
- `:warning` if any warning alert matched
- `:ok` otherwise

`:info` observations may appear in `alerts` if matched, but should not make the
overall status worse than `:ok`.

### 6. Defaults

If `rules:` is empty, return an `:ok` result with no alerts and a summary of the
slice.

Do not invent hidden default production rules in this slice. Apps should pass
explicit rules.

## Non-Goals

- No scheduler.
- No notification delivery.
- No retries.
- No webhook/email/SMS integration.
- No durable monitor state.
- No monitor descriptor registry.
- No policy gate replacement.
- No command execution.
- No Ledger-side monitor runtime.
- No HTTP endpoint.
- No MCP tool.

## Tests

Add focused specs covering:

- `CommandFlowMonitorResult` value object shape, freezing, helpers, `to_h`, `[]`
- empty rules return `:ok`
- all supported metrics
- all supported operators
- severity folding: `:ok`, `:warning`, `:critical`
- `:info` matched alert does not make status warning/critical
- invalid metric/operator/severity raises clear `ArgumentError`
- monitor with provided `slice:` does not recompute by replaying history
- embedded Store monitor over real command-flow history
- client-backed Store monitor over real command-flow history
- app-safe serialization: no raw fact ids, no raw values, no causation internals
- compatibility alias under `Igniter::Companion`

Recommended package checks:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
```

## Acceptance

- `CommandFlowMonitorResult` exists.
- `Igniter::Companion::CommandFlowMonitorResult` compatibility alias exists.
- `Store#command_flow_monitor(...)` exists.
- Embedded and client-backed Stores both work.
- Monitor evaluation is deterministic over a chosen slice/horizon.
- No mutation happens during monitor evaluation.
- No Ledger protocol operation is added.
- Docs/README mention the new monitor layer.
- Full durable-model package specs pass.

## Handoff Notes

Please keep this slice narrow and compositional:

- build on `CommandFlowSlice`
- keep rules as plain data
- avoid a descriptor registry for now
- avoid scheduling and delivery concerns
- keep Ledger Client as transport/protocol boundary only
- do not read the whole repository; this is a Durable Model command monitoring
  read-model slice

This slice should turn temporal command slices into operational signal, while
remaining deterministic, app-owned, and safe for agents to inspect.

## Final Notes

- `CommandFlowMonitorResult` is an app-safe monitor report over
  `CommandFlowSlice`, not durable monitor state.
- `Store#command_flow_monitor` accepts either a provided `slice:` or builds one
  through `command_flow_slice(...)`; it never mutates storage or appends
  activity.
- Rules remain plain data hashes. Supported metrics are `:total`,
  `:status_count`, `:status_ratio`, `:command_count`, `:actor_count`,
  `:subject_count`, and `:request_count`.
- Supported severities are `:info`, `:warning`, and `:critical`; info alerts do
  not worsen the overall status.
- No scheduler, notification delivery, descriptor registry, or Ledger protocol
  operation was added.
