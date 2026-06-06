# Track: Durable Model Command Policy Gate v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Durable Model now has an explicit command pipeline:

```text
command/effect descriptor metadata
-> CommandIntent
-> CommandOperationPlan
-> CommandActivityEvent
-> explicit CommandActivity history append
-> explicit Store#apply_command
-> future policy/capability guarded application
```

`Store#apply_command` is intentionally app-owned. It applies a ready
`CommandOperationPlan` through Durable Model `write`/`append`, not through
Ledger-side command execution.

The next slice adds the first policy/capability gate before application. This
is still not a full authorization framework and not a server security layer.
It is a compact app-boundary decision object plus optional apply guard.

## Goal

Add an explicit policy decision layer:

```ruby
plan = store.command_operation_plan(intent)

decision = store.command_policy_decision(
  plan,
  actor: "user-1",
  capabilities: [:reminder_complete],
  approvals: []
)

receipt = store.apply_command(
  plan,
  policy_decision: decision,
  audit: true
)
```

The decision should be inspectable, app-safe, and usable before mutation.

## Desired Shapes

### 1. Command policy metadata

Extend command metadata support without breaking existing commands:

```ruby
command :complete,
  operation: :record_update,
  changes: { status: :done },
  policy: {
    requires: [:reminder_complete],
    review: false
  }
```

Accepted metadata keys for v0:

- `policy: { requires: [...], review: true/false }`
- `requires: [...]` as shorthand for `policy.requires`
- `review: true/false` as shorthand for `policy.review`

This is metadata only until `command_policy_decision` is called.

### 2. CommandPolicyDecision value object

Add a small app-safe value object, likely:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_policy_decision.rb
```

Suggested fields:

- `schema_version`
- `kind` (`:command_policy_decision`)
- `status` (`:allowed`, `:denied`, `:review_required`)
- `owner`
- `command`
- `subject_key`
- `operation`
- `actor`
- `required_capabilities`
- `granted_capabilities`
- `missing_capabilities`
- `review_required`
- `errors`
- `warnings`
- `metadata`
- `execution_boundary` (`:app`)

Behavior:

- readers
- `allowed?`
- `denied?`
- `review_required?`
- `to_h`
- `[]`
- freeze if consistent with nearby value objects

Do not expose fact ids, value hashes, causation, raw user secrets, or raw
authorization provider payloads.

Expose compatibility alias:

```ruby
Igniter::Companion::CommandPolicyDecision
```

### 3. Decision API

Add:

```ruby
store.command_policy_decision(plan,
  actor: nil,
  capabilities: [],
  approvals: [],
  metadata: {},
  policy: nil)
```

Behavior:

- requires `CommandOperationPlan`
- reads policy from command metadata by owner/command
- merges explicit `policy:` if supplied
- checks required capabilities against `capabilities:`
- if required capabilities are missing -> `status: :denied`
- if `review: true` and no matching approval exists -> `status: :review_required`
- otherwise -> `status: :allowed`
- invalid plans should usually become `status: :denied` with the plan errors
- no storage mutation
- no audit write
- no Ledger protocol operation

Approval matching can be intentionally simple in v0:

```ruby
approvals: [
  { command: :complete, subject_key: "r1", actor: "manager-1" }
]
```

A matching approval may satisfy review requirement when owner/command and
subject_key match. Keep this deliberately app-local and compact.

### 4. Apply integration

Extend:

```ruby
store.apply_command(plan,
  policy_decision: nil,
  require_policy: false,
  ...)
```

Rules:

- default remains backward compatible: no policy required unless
  `require_policy: true` or `policy_decision:` is given.
- when `require_policy: true` and no decision is provided, build one with
  empty capabilities and actor nil.
- when a decision is provided and not allowed, do not mutate.
- rejected apply receipts should include policy errors/warnings and may record
  rejected activity when `audit: true`.
- `CommandApplyReceipt#to_h` should remain app-safe.

Do not let `CommandPolicyDecision` become an authorization token. It is an
app-boundary decision summary. The app still owns the call to `apply_command`.

### 5. Metadata/descriptors

When command descriptors are emitted, include normalized policy metadata if
present:

- required capabilities
- review flag
- boundary remains `:app`

Ledger may store descriptor metadata, but must not evaluate policy.

## Non-Goals

- No full auth framework.
- No users/roles database.
- No token validation.
- No cryptographic grants.
- No server endpoint.
- No MCP tool.
- No Ledger-side policy evaluation.
- No callbacks.
- No automatic command execution.
- No package outside `igniter-durable-model` unless specs require only
  compatibility reads.

## Suggested Read Set

1. `packages/igniter-durable-model/lib/igniter/durable_model/store.rb`
2. `packages/igniter-durable-model/lib/igniter/durable_model/command_intent.rb`
3. `packages/igniter-durable-model/lib/igniter/durable_model/command_operation_plan.rb`
4. `packages/igniter-durable-model/lib/igniter/durable_model/receipts.rb`
5. `packages/igniter-durable-model/lib/igniter/durable_model/record.rb`
6. `packages/igniter-durable-model/spec/igniter/companion/store_spec.rb`
7. `packages/igniter-durable-model/README.md`
8. `packages/igniter-durable-model/README.ru.md`
9. `packages/igniter-durable-model/docs/manifest-glossary.md`

Do not read the whole repository. This is a Durable Model command policy gate
slice.

## Acceptance

Done means:

- `CommandPolicyDecision` exists.
- `Igniter::Companion::CommandPolicyDecision` compatibility alias exists.
- command metadata can declare required capabilities and review requirement.
- `Store#command_policy_decision(plan, ...)` returns allowed/denied/review
  decisions without mutation.
- `Store#apply_command(..., policy_decision:)` refuses non-allowed decisions
  without mutation.
- `Store#apply_command(..., require_policy: true)` builds/checks a decision.
- accepted policy still applies through Durable Model `write`/`append`.
- rejected policy can record rejected command activity when `audit: true`.
- embedded Store and client-backed Store both work.
- command descriptors expose normalized policy metadata.
- Ledger does not execute policy or commands.
- docs explain this as app-boundary policy, not security infrastructure.

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
Track: igniter-durable-model/command-policy-gate-v0
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

- `CommandPolicyDecision` is an app-safe summary with allowed/denied/review
  status, not an authorization token.
- Command descriptors now expose normalized `policy.requires` and
  `policy.review` metadata for introspection only.
- `Store#apply_command` can reject non-allowed decisions or build a default
  decision when `require_policy: true`; rejected applies do not mutate storage.
- Ledger stores descriptors and facts, but does not evaluate policy or execute
  commands.
