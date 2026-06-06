# Track: Durable Model Command Flow Evidence Export v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Durable Model now has portable command-flow evidence profiles:

```text
CommandFlowEvidenceProfile
  = view + optional pin + decision review + decisions + packets + logical links
```

Profiles are good runtime/app objects, but agents, UI, reports, fixtures, and a
future bridge need one more layer:

- deterministic serialization
- content hash
- explicit redaction/privacy policy
- diagnostics when evidence is incomplete
- stable export envelope that can be saved, compared, or shared

This slice should stay package-local. It is not an Igniter-Lang `ObsPacket`
implementation and must not introduce bridge/runtime semantics.

## Goal

Add a read-only export bundle for command-flow evidence profiles.

Desired usage:

```ruby
profile = store.command_flow_evidence_profile(
  view_name: :dispatch_assignment_health,
  action: :mutate,
  actor: "dispatcher-1",
  capabilities: [:dispatch_review]
)

export = store.export_command_flow_evidence_profile(profile,
  privacy: :app_safe,
  include_packets: true,
  metadata: { source: :ops_dashboard })

export.content_hash
export.canonical_json
export.diagnostics
export.redactions
```

Also support direct construction:

```ruby
export = store.command_flow_evidence_export(
  view_name: :dispatch_assignment_health,
  action: :mutate,
  privacy: :hash_payloads)
```

## Required Shape

### 1. Add `CommandFlowEvidenceExport`

Add a focused value object, likely:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_flow_evidence_export.rb
```

Suggested fields:

- `schema_version`
- `kind` (`:command_flow_evidence_export`)
- `export_id`
- `profile_kind`
- `owner`
- `view_name`
- `action`
- `actor`
- `status`
- `meaning_status`
- `privacy`
- `generated_at`
- `content_hash`
- `canonical_json`
- `profile`
- `packets`
- `links`
- `diagnostics`
- `redactions`
- `metadata`
- `store_fact_exposed`
- `value_hash_exposed`

Rules:

- freeze the object and nested data where practical
- expose `to_h` and `[]`
- no raw Ledger fact ids, value hashes, or causation internals
- `export_id` should be app-safe and derived from `content_hash`
- expose `Igniter::Companion::CommandFlowEvidenceExport` compatibility alias

### 2. Add Export APIs

Add:

```ruby
store.export_command_flow_evidence_profile(profile,
  privacy: :app_safe,
  include_packets: true,
  include_decisions: true,
  metadata: {})
```

and convenience:

```ruby
store.command_flow_evidence_export(view_name:,
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
  privacy: :app_safe,
  include_packets: true,
  include_decisions: true,
  metadata: {})
```

Behavior:

- build on `command_flow_evidence_profile`
- export an existing profile without re-evaluating when given a profile object
- return `CommandFlowEvidenceExport`
- do not append history
- do not mutate records
- do not execute commands
- do not append command activity
- do not add Ledger protocol operations

### 3. Privacy Policies

Support simple v0 privacy policies:

| Policy | Meaning |
|--------|---------|
| `:app_safe` | keep profile's existing app-safe fields |
| `:summary_only` | keep status, meaning, horizon, summary, findings, links; drop detailed decisions and packet payloads |
| `:hash_payloads` | replace packet/profile payload-heavy fields with hashes while preserving ids, subjects, statuses, and links |

Unknown policy should raise clear `ArgumentError`.

`redactions` should record what was removed or hashed:

```ruby
[
  { path: [:packets, 0, :payload], action: :hashed, hash: "..." },
  { path: [:decisions], action: :removed, count: 12 }
]
```

### 4. Canonicalization

Add deterministic canonical JSON for export comparison and golden fixtures.

Rules:

- stable key ordering
- stable symbol/string normalization
- stable time representation
- deterministic hashes for identical exported content
- use only Ruby stdlib
- document that v0 canonicalization is package-local, not a cross-language
  canonical serializer promise

Suggested:

```ruby
canonical_json = JSON.generate(canonical_hash)
content_hash = Digest::SHA256.hexdigest(canonical_json)
export_id = "cfe_#{content_hash[0, 16]}"
```

If existing package helpers already provide deterministic serialization, use
them instead.

### 5. Diagnostics

Export should include diagnostics for under-specified evidence:

- missing pin when action was requested but pin failed to build
- blocked pin
- unknown/provisional/mixed meaning status
- critical review
- empty decision review when decisions were expected
- packet payload omitted by privacy policy
- hash-only payloads

Diagnostics are advisory and app-safe. They do not change the underlying
profile.

Suggested shape:

```ruby
{
  code: :evidence_profile_blocked,
  severity: :warning,
  message: "Profile includes a blocked pin"
}
```

### 6. Golden Fixture Readiness

This slice should make it easy to create deterministic fixtures later, but it
does not need to add a fixtures directory unless useful.

Acceptance is satisfied if tests prove that identical profile/export inputs
produce identical `canonical_json`, `content_hash`, and `export_id`.

## Non-Goals

- No Igniter-Lang dependency.
- No formal `ObsPacket` implementation.
- No bridge sidecar package.
- No HTTP endpoint.
- No MCP tool.
- No decision persistence.
- No command execution.
- No business record mutation.
- No Ledger protocol operation.
- No global cross-language canonical serializer promise.

## Tests

Add focused specs covering:

- `CommandFlowEvidenceExport` value object shape, freezing, `to_h`, `[]`
- export from an existing `CommandFlowEvidenceProfile`
- convenience export builds profile once and exports it
- deterministic `canonical_json`, `content_hash`, and `export_id`
- privacy `:app_safe`
- privacy `:summary_only`
- privacy `:hash_payloads`
- unknown privacy raises `ArgumentError`
- redactions are recorded
- diagnostics for blocked/unknown/critical/empty evidence
- include/exclude packets
- include/exclude decisions
- no raw fact ids, raw value hashes, or causation internals
- embedded Store path
- client-backed Store path where evidence profile works
- export does not append history
- export does not append command activity
- export does not mutate records
- compatibility alias under `Igniter::Companion`

Recommended package checks:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
```

## Acceptance

- `CommandFlowEvidenceExport` exists.
- `Igniter::Companion::CommandFlowEvidenceExport` alias exists.
- `Store#export_command_flow_evidence_profile(...)` exists.
- `Store#command_flow_evidence_export(...)` exists.
- Exports are deterministic for identical inputs.
- Exports have content hash and app-safe export id.
- Privacy policies and redactions work.
- Diagnostics expose incomplete or downgraded evidence.
- Export is read-only and app-safe.
- Docs/README mention evidence exports.
- Full durable-model package specs pass.

## Handoff Notes

Please keep this as an export/canonicalization slice:

- build on `CommandFlowEvidenceProfile`
- do not introduce bridge runtime semantics
- do not import Igniter-Lang
- do not add transport endpoints
- do not persist exports automatically
- keep canonicalization package-local and explicitly v0
- keep all ids app-safe

This slice should make evidence profiles stable enough for humans, agents, and
golden fixtures without turning Durable Model into the Igniter-Lang bridge.

## Final Notes

Implemented as a deterministic read-only export envelope:

- Added `CommandFlowEvidenceExport` with frozen app-safe serialization,
  canonical JSON, SHA256 content hash, `cfe_...` export id, diagnostics,
  redactions, packets, links, and metadata.
- Added `Igniter::Companion::CommandFlowEvidenceExport` compatibility alias.
- Added `Store#export_command_flow_evidence_profile` for exporting an existing
  `CommandFlowEvidenceProfile` without re-evaluating it.
- Added `Store#command_flow_evidence_export` convenience API.
- Implemented package-local v0 canonicalization with stable key ordering,
  symbol/string normalization, stable Time formatting, and stdlib JSON/Digest.
- Implemented `:app_safe`, `:summary_only`, and `:hash_payloads` privacy
  policies with redaction records.
- Added diagnostics for blocked profiles, incomplete meaning, critical reviews,
  empty decisions, omitted packets, omitted payloads, and hash-only payloads.
- Export remains read-only: it does not append decision history, append command
  activity, mutate records, execute commands, persist exports, add endpoints, or
  add Ledger protocol operations.
- Covered deterministic exports, all privacy policies, redactions,
  diagnostics, include/exclude packets and decisions, embedded path,
  client-backed path, read-only behavior, and compatibility alias.
