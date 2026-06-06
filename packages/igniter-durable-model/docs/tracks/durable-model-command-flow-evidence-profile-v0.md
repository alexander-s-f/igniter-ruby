# Track: Durable Model Command Flow Evidence Profile v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Durable Model now has a strong command-flow evidence chain:

```text
CommandFlow
  -> CommandFlowSlice
  -> CommandFlowMonitorResult
  -> CommandFlowView
  -> CommandFlowViewPin
  -> CommandFlowDecision history
  -> CommandFlowDecisionReview
```

Each piece is useful, but consumers still have to manually stitch them together
when they want a compact artifact for UI, agent review, export, or a future
Igniter-Lang bridge.

The next package-local slice should introduce a **single app-safe evidence
profile** that bundles the relevant command-flow artifacts and names their
logical links. This should remain Durable Model vocabulary, not a dependency on
Igniter-Lang `ObsPacket` yet.

## Goal

Add a reusable read-only evidence profile over command-flow operational state.

Desired usage:

```ruby
profile = store.command_flow_evidence_profile(
  view_name: :dispatch_assignment_health,
  action: :mutate,
  actor: "dispatcher-1",
  capabilities: [:dispatch_review],
  since: Time.now.utc - 3600,
  decision_rules: [
    { name: :blocked, metric: :status_count, status: :blocked, op: :>=, value: 1 }
  ],
  metadata: { source: :ops_dashboard }
)

profile.status          # :ok / :warning / :critical / :blocked
profile.meaning_status  # :reproducible / :live / :provisional / :unknown / :mixed
profile.view            # app-safe view hash
profile.pin             # app-safe pin hash, if action was supplied
profile.review          # app-safe decision review hash
profile.packets         # compact evidence packet candidates
profile.links           # logical links between artifacts
```

This gives applications one stable object to hand to UI, agents, exports, and
future bridge code.

## Required Shape

### 1. Add `CommandFlowEvidenceProfile`

Add a focused value object, likely:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_flow_evidence_profile.rb
```

Suggested fields:

- `schema_version`
- `kind` (`:command_flow_evidence_profile`)
- `owner`
- `view_name`
- `action`
- `actor`
- `status`
- `meaning_status`
- `generated_at`
- `horizon`
- `view`
- `pin`
- `review`
- `decisions`
- `packets`
- `links`
- `metadata`
- `store_fact_exposed`
- `value_hash_exposed`

Rules:

- freeze the object and nested data where practical
- expose `to_h` and `[]`
- no raw Ledger fact ids, value hashes, or causation internals
- preserve app-safe logical ids such as view names, pin receipt ids, and
  decision receipt ids
- expose `Igniter::Companion::CommandFlowEvidenceProfile` compatibility alias

### 2. Add `Store#command_flow_evidence_profile`

Add:

```ruby
store.command_flow_evidence_profile(view_name:,
  action: nil,
  actor: nil,
  capabilities: [],
  since: nil,
  as_of: nil,
  decision_status: nil,
  decision_meaning_status: nil,
  decision_receipt_id: nil,
  decision_limit: nil,
  decision_rules: [],
  metadata: {})
```

Behavior:

- evaluate the named `CommandFlowView`
- optionally pin it when `action:` is supplied
- build a `CommandFlowDecisionReview` for the view owner/name and supplied
  decision filters/rules
- include compact decision entries from the review
- return `CommandFlowEvidenceProfile`
- do not append decision history
- do not append command activity
- do not mutate business records
- do not execute commands
- do not add Ledger protocol operations
- work for embedded and client-backed Stores where the underlying view/review
  paths already work

### 3. Status and Meaning Folding

Profile status should fold over included artifacts:

- `:critical` if review is critical
- `:warning` if review is warning or view/monitor is warning
- `:blocked` if pin exists and is blocked
- `:ok` otherwise

Profile `meaning_status` should be conservative:

- `:reproducible` only when the pin/view horizon is reproducible and no included
  artifact has unknown/provisional meaning
- `:live` for live view horizons with no stronger issue
- `:mixed` when decisions contain multiple meaning statuses
- `:unknown` when a blocked pin or missing evidence prevents stronger meaning

Keep this simple in v0. The important rule is: do not overclaim.

### 4. Evidence Packet Candidates

Add compact package-local packet candidates, not Igniter-Lang `ObsPacket`.

Suggested packet shape:

```ruby
{
  schema_version: 1,
  kind: :command_flow_view_evidence,
  subject: "durable-model://command-flow/views/dispatch_assignment_health",
  meaning_status: :live,
  payload: { ... app-safe data ... },
  links: [
    { rel: :derived_from, ref: "durable-model://command-flow/owners/orders" }
  ],
  policy: {
    store_fact_exposed: false,
    value_hash_exposed: false
  }
}
```

Recommended packet kinds:

- `:command_flow_view_evidence`
- `:command_flow_pin_evidence`
- `:command_flow_decision_review_evidence`
- `:command_flow_decision_evidence`

These are bridge-ready shapes, but they must not import or depend on
`igniter-lang`.

### 5. Logical Links

Expose a compact `links` array for the whole profile:

- view -> owner
- pin -> view
- review -> view
- decision -> pin receipt id, when available
- decision -> decision receipt id, when available

Suggested link shape:

```ruby
{ rel: :reviews, from: "durable-model://...", to: "durable-model://..." }
```

Use stable app-safe string refs. Do not use raw object ids or Ledger fact ids.

## Non-Goals

- No Igniter-Lang dependency.
- No formal `ObsPacket` implementation.
- No automatic decision persistence.
- No command execution.
- No business record mutation.
- No scheduler.
- No notification delivery.
- No HTTP endpoint.
- No MCP tool.
- No Ledger protocol operation.
- No durable workflow engine.

## Tests

Add focused specs covering:

- `CommandFlowEvidenceProfile` value object shape, freezing, `to_h`, `[]`
- profile with view only
- profile with view + pin
- profile with view + blocked pin
- profile with decision review and decision entries
- profile status folding: ok, warning, critical, blocked
- conservative `meaning_status` folding
- generated packet kinds and stable subject refs
- logical link shape and ids
- no raw fact ids, raw value hashes, or causation internals in profile or packets
- embedded Store path
- client-backed Store path, if existing command-flow view/review support allows
- profile does not append history
- profile does not append `CommandActivity`
- profile does not mutate records
- compatibility alias under `Igniter::Companion`

Recommended package checks:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
```

## Acceptance

- `CommandFlowEvidenceProfile` exists.
- `Igniter::Companion::CommandFlowEvidenceProfile` alias exists.
- `Store#command_flow_evidence_profile(...)` exists.
- Profile bundles view, optional pin, decision review, decisions, packets, and
  links.
- Profile remains read-only and app-safe.
- Packet candidates are package-local and bridge-ready but not `ObsPacket`.
- Embedded path works.
- Client-backed path works when the underlying view/review path works; if a
  limitation exists, document it explicitly in final notes.
- Docs/README mention evidence profiles.
- Full durable-model package specs pass.

## Handoff Notes

Please keep this as a packaging/read-model slice:

- build on existing command-flow view, pin, decision, and review objects
- do not create a workflow engine
- do not introduce transport endpoints
- do not import Igniter-Lang
- do not add Ledger protocol operations
- keep every exported id app-safe and stable
- avoid reading the whole repository; this is a Durable Model evidence-profile
  slice

This slice should make command-flow evidence portable enough for UI and agents,
while keeping the formal bridge to Igniter-Lang as a later explicit step.

## Final Notes

Implemented as a read-only package-local evidence bundle:

- Added `CommandFlowEvidenceProfile` with frozen app-safe serialization,
  artifact hashes, packets, links, status/meaning status, horizon, and
  metadata.
- Added `Igniter::Companion::CommandFlowEvidenceProfile` compatibility alias.
- Added `Store#command_flow_evidence_profile`.
- Profiles evaluate the named `CommandFlowView`, optionally pin when `action:`
  is supplied, build `CommandFlowDecisionReview`, include compact decisions,
  and return stable packet/link shapes.
- Packet candidates use package-local `:command_flow_*_evidence` kinds and
  `durable-model://...` refs; no Igniter-Lang dependency or `ObsPacket`
  implementation was introduced.
- Profiles are read-only: they do not append decision history, append command
  activity, mutate records, execute commands, or add Ledger protocol
  operations.
- Covered view-only, pinned, blocked, decision-review, packet/link, status
  folding, meaning folding, app-safe serialization, embedded path, and
  client-backed path.
