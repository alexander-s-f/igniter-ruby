# Track: Durable Model Command Flow Temporal Slices v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Durable Model now has a full app-owned command pipeline:

```text
descriptor metadata
-> CommandIntent
-> CommandOperationPlan
-> CommandActivityEvent
-> CommandActivity history
-> CommandPolicyDecision
-> Store#apply_command
-> CommandLifecycle
-> CommandFlow
```

`CommandFlow` is the right single-command UX surface. The next useful step is
not a new executor and not a Ledger protocol operation. The next step is a
temporal read model over command activity: application code and agents need to
ask "what happened with commands in this window?" without exposing raw Ledger
facts or requiring every app to hand-roll history folding.

This slice is also the Durable Model-side pressure from the Igniter-Lang thesis:

```text
contract + explicit time + projection/slice = reproducible meaning
```

## Goal

Add app-safe temporal command-flow slices over `CommandActivity` history.

Desired usage:

```ruby
slice = store.command_flow_slice(
  owner: :reminders,
  command: :complete,
  status: :applied,
  actor: "user-1",
  since: Time.utc(2026, 1, 1),
  as_of: Time.utc(2026, 1, 31),
  limit: 50
)

slice.status_counts # => { applied: 12, policy_denied: 2 }
slice.items         # => app-safe command flow summaries
slice.to_h          # => serializable, no raw Ledger facts/value hashes
```

The output should support dashboards, agent review, audit summaries, and future
Spark CRM-style monitoring without coupling Durable Model to a UI.

## Required Shape

### 1. Add `CommandFlowSlice`

Add a value object, likely:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_flow_slice.rb
```

Suggested fields:

- `schema_version`
- `kind` (`:command_flow_slice`)
- `owner`
- `filters`
- `since`
- `as_of`
- `limit`
- `items`
- `summary`
- `status_counts`
- `command_counts`
- `actor_counts`
- `subject_count`
- `request_count`
- `generated_at`
- `execution_boundary` (`:app`)
- `store_fact_exposed`
- `value_hash_exposed`

Behavior:

- readers
- `empty?`
- `size`
- `[]`
- `to_h`
- freeze if consistent with nearby value objects

Expose compatibility alias:

```ruby
Igniter::Companion::CommandFlowSlice
```

### 2. Add app-safe slice items

Either add `CommandFlowSliceItem` or use compact hashes internally, but the
public serialized item shape should be stable and app-safe.

Suggested item fields:

- `owner`
- `command`
- `subject_key`
- `request_id`
- `actor`
- `status`
- `intent_status`
- `plan_status`
- `policy_status`
- `apply_status`
- `operation`
- `target`
- `first_seen_at`
- `last_seen_at`
- `activity_count`
- `errors`
- `warnings`
- `metadata`

Rules:

- group activity by `request_id` when present
- fall back to `[owner, command, subject_key, timestamp/order]` only if
  `request_id` is absent in old data
- do not expose raw fact ids
- do not expose raw command values
- do not expose provider payloads

### 3. Add `Store#command_flow_slice`

Add:

```ruby
store.command_flow_slice(owner:,
  command: nil,
  subject_key: nil,
  request_id: nil,
  actor: nil,
  status: nil,
  since: nil,
  as_of: nil,
  limit: nil,
  history_class: Igniter::DurableModel::CommandActivity)
```

Behavior:

- reads `CommandActivity` history only
- applies temporal filters through existing replay paths
- folds events into command-flow slice items
- applies filters before final limit where possible
- returns `CommandFlowSlice`
- works in embedded and client-backed Store

Do not add Ledger protocol operations. Client-backed mode should lower through
existing history replay/filter capabilities.

### 4. Temporal Semantics

Use explicit temporal language:

- `since:` means inclusive lower bound
- `as_of:` means inclusive upper bound / observation horizon
- if both are nil, observe all retained command activity
- `generated_at` is when the slice object was created
- `as_of` is the logical observation horizon, not necessarily `generated_at`

If current replay helpers already define slightly different boundary behavior,
prefer consistency with existing behavior and document it in the track result.

### 5. Status Folding

Fold command activity statuses into one item status.

Suggested precedence:

1. `:applied`
2. `:review_required`
3. `:policy_denied`
4. `:rejected`
5. `:planned`
6. `:unknown`

If existing `CommandLifecycle` already has status folding logic, reuse it rather
than duplicating a competing algorithm.

### 6. Optional Convenience Summary

If it stays compact, add:

```ruby
store.command_flow_summary(...)
```

This may simply call `command_flow_slice(...).summary`.

Only add it if it does not create API noise. The core deliverable is
`CommandFlowSlice`.

## Non-Goals

- No Ledger-side command execution.
- No workflow engine.
- No saga engine.
- No retries.
- No HTTP endpoint.
- No MCP tool.
- No new Ledger protocol operation.
- No durable aggregate table.
- No cross-store relation resolution in this slice.

## Tests

Add focused specs covering:

- `CommandFlowSlice` value object shape, freezing, `to_h`, `[]`, `empty?`, `size`
- embedded Store slice over multiple command requests
- client-backed Store slice over multiple command requests
- filters: `owner`, `command`, `subject_key`, `request_id`, `actor`, `status`
- temporal filters: `since`, `as_of`, and combined window
- `limit`
- status folding for planned/applied/rejected/policy_denied/review_required
- status/command/actor counts
- app-safe serialization: no raw fact ids, no raw values, no causation internals
- compatibility alias under `Igniter::Companion`

Recommended package checks:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
```

## Acceptance

- `CommandFlowSlice` exists.
- `Igniter::Companion::CommandFlowSlice` compatibility alias exists.
- `Store#command_flow_slice(...)` exists.
- Embedded and client-backed Stores both work.
- Slices are deterministic over the chosen command activity horizon.
- The API is app-safe and does not expose raw Ledger internals.
- Docs/README mention the new slice.
- Full durable-model package specs pass.

## Handoff Notes

Please keep the implementation narrow and compositional:

- reuse `CommandLifecycle` folding if possible
- reuse existing replay/history APIs
- keep Ledger Client as transport/protocol boundary only
- do not introduce a new storage abstraction
- do not read the whole repository; this is a Durable Model command read-model
  slice

This slice is intentionally the first bridge from "single command flow" to
"temporal operational meaning". It should feel like a read model/projection, not
like a workflow runtime.

## Final Notes

- `CommandFlowSlice` is an app-safe temporal read model over `CommandActivity`
  history, not an aggregate table or workflow runtime.
- `Store#command_flow_slice` uses existing `replay` / partition replay paths;
  no Ledger protocol operation was added.
- Slice items group by `metadata[:request_id]` when present and use a per-event
  fallback for old activity without request ids.
- `since:` is treated as the inclusive lower bound and `as_of:` as the
  inclusive observation horizon, matching existing replay semantics.
- `Store#command_flow_summary` is a compact convenience wrapper around
  `command_flow_slice(...).summary`.
