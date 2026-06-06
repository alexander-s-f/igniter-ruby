# Track: Durable Model Command Flow Evidence Archive v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

Durable Model now has deterministic command-flow evidence exports:

```text
CommandFlowEvidenceProfile
  -> CommandFlowEvidenceExport
  -> canonical_json + content_hash + privacy + diagnostics + redactions
```

Exports are read-only and not persisted automatically. That is the right v0
boundary. The next useful slice is an explicit app-owned archive and verification
layer:

- applications can choose to archive an export
- archived exports can be replayed by owner/view/hash/id
- exports can be verified later against their canonical hash
- no command execution or bridge runtime semantics are introduced

This mirrors the pattern already used for decision history: compute/read first,
then explicit append only when the application asks.

## Goal

Add explicit persistence and verification for command-flow evidence exports.

Desired usage:

```ruby
export = store.command_flow_evidence_export(
  view_name: :dispatch_assignment_health,
  action: :mutate,
  privacy: :summary_only)

receipt = store.archive_command_flow_evidence_export(export,
  metadata: { case_id: "dispatch-42" })

archived = store.command_flow_evidence_archives(
  owner: :orders,
  view_name: :dispatch_assignment_health,
  content_hash: export.content_hash)

verification = store.verify_command_flow_evidence_export(export)
verification.status # :valid / :invalid
```

## Required Shape

### 1. Add `CommandFlowEvidenceArchive`

Add a built-in History schema, likely:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_flow_evidence_archive.rb
```

Suggested shape:

```ruby
class CommandFlowEvidenceArchive
  include Igniter::DurableModel::History

  history_name :command_flow_evidence_archives
  partition_key :owner

  field :owner
  field :view_name
  field :action, default: nil
  field :actor, default: nil
  field :export_id
  field :content_hash
  field :privacy
  field :status
  field :meaning_status
  field :profile_kind
  field :canonical_json
  field :diagnostics, default: []
  field :redactions, default: []
  field :metadata, default: {}
  field :store_fact_exposed, default: false
  field :value_hash_exposed, default: false
end
```

Expose compatibility alias:

```ruby
Igniter::Companion::CommandFlowEvidenceArchive
```

### 2. Add `CommandFlowEvidenceArchiveReceipt`

Add an app-safe receipt value object, either in `receipts.rb` or a focused file.

Suggested fields:

- `schema_version`
- `kind` (`:command_flow_evidence_archive_receipt`)
- `status` (`:archived`, `:rejected`)
- `archive_receipt_id`
- `export_id`
- `content_hash`
- `owner`
- `view_name`
- `privacy`
- `meaning_status`
- `diagnostics`
- `metadata`
- `generated_at`
- `store_fact_exposed`
- `value_hash_exposed`

Rules:

- no raw Ledger fact ids
- no value hashes from Ledger internals
- no causation internals
- receipt ids are app-local

Expose compatibility alias:

```ruby
Igniter::Companion::CommandFlowEvidenceArchiveReceipt
```

### 3. Add `CommandFlowEvidenceExportVerification`

Add a frozen read-only value object:

```text
packages/igniter-durable-model/lib/igniter/durable_model/command_flow_evidence_export_verification.rb
```

Suggested fields:

- `schema_version`
- `kind` (`:command_flow_evidence_export_verification`)
- `status` (`:valid`, `:invalid`)
- `export_id`
- `expected_hash`
- `actual_hash`
- `privacy`
- `diagnostics`
- `metadata`
- `generated_at`

Expose compatibility alias:

```ruby
Igniter::Companion::CommandFlowEvidenceExportVerification
```

### 4. Add Archive APIs

Add:

```ruby
store.archive_command_flow_evidence_export(export,
  history_class: Igniter::DurableModel::CommandFlowEvidenceArchive,
  metadata: {})
```

Behavior:

- require `export` to be `CommandFlowEvidenceExport`
- verify canonical hash before append
- append one archive entry
- merge explicit metadata with export metadata under app-safe rules
- return `CommandFlowEvidenceArchiveReceipt`
- do not rebuild/re-evaluate the source profile
- do not append decision history
- do not append command activity
- do not mutate business records
- do not execute commands
- do not add Ledger protocol operations

Add:

```ruby
store.command_flow_evidence_archives(owner:,
  view_name: nil,
  action: nil,
  actor: nil,
  export_id: nil,
  content_hash: nil,
  privacy: nil,
  status: nil,
  meaning_status: nil,
  since: nil,
  as_of: nil,
  limit: nil,
  history_class: Igniter::DurableModel::CommandFlowEvidenceArchive)
```

Behavior:

- replay archive history by owner partition
- apply filters and temporal window
- return typed `CommandFlowEvidenceArchive` entries
- support embedded and client-backed Stores through existing history replay

### 5. Add Verification API

Add:

```ruby
store.verify_command_flow_evidence_export(export, metadata: {})
```

Behavior:

- recompute the SHA256 of `export.canonical_json`
- compare to `export.content_hash`
- return `CommandFlowEvidenceExportVerification`
- do not append anything
- include diagnostics when invalid

If compact, also support verifying an archived record:

```ruby
store.verify_command_flow_evidence_archive(archive, metadata: {})
```

This should parse or use `archive.canonical_json`, recompute the hash, and
compare it to `archive.content_hash`.

## Non-Goals

- No automatic export archive.
- No command execution.
- No business record mutation.
- No scheduler.
- No notification delivery.
- No HTTP endpoint.
- No MCP tool.
- No Ledger protocol operation.
- No Igniter-Lang dependency.
- No formal `ObsPacket` implementation.
- No cross-language canonical serializer promise.

## Tests

Add focused specs covering:

- `CommandFlowEvidenceArchive` History schema shape and partition
- `CommandFlowEvidenceArchiveReceipt` shape, freezing, `to_h`, `[]`
- `CommandFlowEvidenceExportVerification` shape, freezing, `to_h`, `[]`
- verify valid export
- verify tampered/invalid export
- archive valid export
- archive rejects invalid export or returns rejected receipt with diagnostics
- archive keeps canonical_json/content_hash/export_id/privacy
- explicit metadata merge
- archive filters: view_name, action, actor, export_id, content_hash, privacy,
  status, meaning_status
- temporal filters: since/as_of
- limit
- embedded Store path
- client-backed Store path
- archive does not rebuild/re-evaluate profile
- archive does not append decision history
- archive does not append command activity
- archive does not mutate records
- no raw fact ids, raw value hashes, or causation internals are exposed
- compatibility aliases under `Igniter::Companion`

Recommended package checks:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
```

## Acceptance

- `CommandFlowEvidenceArchive` exists.
- `CommandFlowEvidenceArchiveReceipt` exists.
- `CommandFlowEvidenceExportVerification` exists.
- `Igniter::Companion` compatibility aliases exist.
- `Store#archive_command_flow_evidence_export(...)` exists.
- `Store#command_flow_evidence_archives(...)` exists.
- `Store#verify_command_flow_evidence_export(...)` exists.
- Embedded and client-backed Stores both work.
- Archive is explicit only.
- Archive/verification remain app-safe and package-local.
- Docs/README mention evidence archives.
- Full durable-model package specs pass.

## Handoff Notes

Please keep this as an explicit archive/verification slice:

- build on `CommandFlowEvidenceExport`
- never archive automatically
- verify before archive
- keep archived identity app-safe: `export_id`, `content_hash`, owner/view/action
- do not introduce bridge runtime semantics
- do not import Igniter-Lang
- do not add transport endpoints
- avoid reading the whole repository; this is a Durable Model archive slice

This slice should make evidence exports durable when applications explicitly
choose audit/archive behavior, while keeping profile/export generation read-only.

## Final Notes

Implemented as explicit app-owned archive and verification:

- Added `CommandFlowEvidenceArchive` built-in history with
  `history_name :command_flow_evidence_archives` and `partition_key :owner`.
- Added `CommandFlowEvidenceArchiveReceipt` app-safe receipt.
- Added `CommandFlowEvidenceExportVerification` read-only value object.
- Added `Igniter::Companion` aliases for all three.
- Added `Store#verify_command_flow_evidence_export` and
  `Store#verify_command_flow_evidence_archive`.
- Added `Store#archive_command_flow_evidence_export`; invalid exports return a
  rejected receipt and are not appended.
- Added `Store#command_flow_evidence_archives` with owner-partition replay,
  filters, temporal windows, and limit.
- Archive is explicit only and does not rebuild profiles, append decision
  history, append command activity, mutate records, execute commands, or add
  Ledger protocol operations.
- Covered valid/invalid verification, valid archive, rejected invalid archive,
  embedded and client-backed paths, metadata merge, filters, temporal windows,
  limit, read-only behavior, app-safe receipts, and compatibility aliases.
