# igniter-durable-model

Durable Model: the application-facing Record/History layer backed by
`igniter-ledger`.

Status: active pre-v1 platform lane. The package is now
`igniter-durable-model`, and the canonical Ruby namespace is
`Igniter::DurableModel`.

## Purpose

This package is the **Durable Model layer over `igniter-ledger` for application
code**.

It serves two goals:

1. **App-facing surface** — shows what working with facts looks like from
   contract/application code: typed `Record` objects, append-only `History`
   streams, scope queries, generated schemas, and normalized receipts.

2. **Pressure on the core** — every new capability at this level surfaces gaps, friction, or bugs in `igniter-ledger`. This is intentional. Insights are recorded in the [Pressure & Insights](#pressure--insights) section below.

### The Tunnel Metaphor

```
examples/application/companion   ←── app-level contracts, manifests, materializer
                   │
                   │  digging toward each other
                   ▼
  packages/igniter-durable-model      ←── Durable Model DSL on top of igniter-ledger
                   │
                   ▼
  packages/igniter-ledger          ←── facts, WAL, scope, reactive (Rust/Ruby FFI)
```

**Convergence point**: when `PersistenceSketchPack` in `examples/application/companion`
drives its records through `Igniter::DurableModel::Store` instead of blob-JSON in SQLite.

## Docs

See [`docs/`](docs/) for status summaries, manifest glossary, and performance signals:

- [docs/current-status.md](docs/current-status.md) — current implementation status
- [docs/app-status.md](docs/app-status.md) — app-local persistence proof status
- [docs/manifest-glossary.md](docs/manifest-glossary.md) — persistence manifest glossary
- [docs/performance.md](docs/performance.md) — contract performance signal notes

---

## Architecture

```
lib/igniter/durable_model.rb
lib/igniter/durable_model/
  record.rb    — Record mixin: store_name, field, scope DSL → typed objects
  history.rb   — History mixin: history_name, field → append-only events
  store.rb     — Store: register, write, read, scope, append, replay, on_scope
```

```ruby
require "igniter/durable_model"
```

### `Record`

Wraps `Store[T]` from igniter-ledger. The latest written value is the current state.

```ruby
class Reminder
  include Igniter::DurableModel::Record
  store_name :reminders

  field :title
  field :status, default: :open
  field :due,    default: nil

  scope :open, filters: { status: :open }
  scope :done, filters: { status: :done }, cache_ttl: 30
end
```

### `History`

Wraps `History[T]` from igniter-ledger. Append-only; keys are auto-generated.

```ruby
class TrackerLog
  include Igniter::DurableModel::History
  history_name :tracker_logs
  partition_key :tracker_id   # enables partition replay

  field :tracker_id
  field :value
  field :notes, default: nil
end
```

### `Store`

Orchestrator — holds the `IgniterStore` instance, knows about registered schemas.

```ruby
store = Igniter::DurableModel::Store.new         # in-memory (default)
store = Igniter::DurableModel::Store.new(        # file-backed WAL
  backend: :file,
  path:    "/tmp/durable-model.wal"
)

store.register(Reminder)   # registers an AccessPath for each declared scope

store.write(Reminder, key: "r1", title: "Buy milk", status: :open)
store.read(Reminder,  key: "r1")                 # => #<Reminder key="r1" ...>
store.scope(Reminder, :open)                     # => [#<Reminder ...>, ...]
store.scope(Reminder, :open, as_of: checkpoint)  # time-travel

store.append(TrackerLog, tracker_id: "t1", value: 8.5)
store.replay(TrackerLog)                         # => [#<TrackerLog ...>, ...]
store.replay(TrackerLog, since: cutoff)          # time-filtered
store.replay(TrackerLog, partition: "sleep")     # filtered by partition_key value

store.causation_chain(Reminder, key: "r1")       # mutation chain for debugging
store.lineage(Reminder, key: "r1")               # compact provenance proof
```

### Compatibility

The older `lib/igniter/companion` load path and `Igniter::Companion` namespace
remain available for pre-rename callers and for the Companion app proof:

```ruby
require "igniter/companion"

Igniter::Companion::Store # => Igniter::DurableModel::Store
```

#### Remote Ledger Client Boundary

For remote Ledger deployments, prefer the standard `igniter-ledger-client`
boundary over the older `backend: :network` transport proof:

```ruby
client = Igniter::LedgerClient.remote_http(
  "http://127.0.0.1:7300/v1/dispatch",
  events_url: "http://127.0.0.1:7300/v1/events"
)
store = Igniter::DurableModel::Store.new(client: client)

store.register(Reminder)
store.write(Reminder, key: "r1", title: "Buy milk", status: :open)
store.read(Reminder, key: "r1")
store._commands
store._effects
intent = store.command_intent(Reminder, :complete, key: "r1")
plan = store.command_operation_plan(intent)
event = store.command_activity_event(plan)
store.append_command_activity(event)
decision = store.command_policy_decision(plan,
  actor: "user-1",
  capabilities: [:reminder_complete])
store.apply_command(plan, policy_decision: decision, audit: true)
store.command_lifecycle(
  owner: :reminders,
  command: :complete,
  subject_key: "r1")
store.command_flow(Reminder, :complete,
  key: "r1",
  actor: "user-1",
  capabilities: [:reminder_complete],
  mode: :preview)
store.command_flow_slice(
  owner: :reminders,
  status: :applied,
  since: Time.utc(2026, 1, 1))
store.command_flow_monitor(
  owner: :reminders,
  rules: [{
    name: :denials,
    metric: :status_count,
    status: :policy_denied,
    op: :>,
    value: 0
  }])
store.register_command_flow_view(:reminder_flow_health,
  owner: :reminders,
  command: :complete,
  horizon: { mode: :live, as_of: :latest },
  action_policy: {
    inspect: true,
    mutate: :requires_pinned_horizon
  },
  rules: [{
    name: :denials,
    metric: :status_count,
    status: :policy_denied,
    op: :>,
    value: 0
  }])
store.command_flow_view(:reminder_flow_health)
store.pin_command_flow_view(:reminder_flow_health,
  action: :mutate,
  capabilities: [:dispatch_review])
pin = store.pin_command_flow_view(:reminder_flow_health,
  action: :inspect,
  capabilities: [:dispatch_review])
store.append_command_flow_decision(pin)
store.command_flow_decisions(
  owner: :reminders,
  view_name: :reminder_flow_health)
store.command_flow_decision_review(
  owner: :reminders,
  view_name: :reminder_flow_health,
  rules: [{
    name: :blocked,
    metric: :status_count,
    status: :blocked,
    op: :>=,
    value: 1
  }])
store.command_flow_evidence_profile(
  view_name: :reminder_flow_health,
  action: :inspect,
  capabilities: [:dispatch_review],
  decision_rules: [{
    name: :blocked,
    metric: :status_count,
    status: :blocked,
    op: :>=,
    value: 1
  }])
store.command_flow_evidence_export(
  view_name: :reminder_flow_health,
  action: :inspect,
  privacy: :summary_only)
export = store.command_flow_evidence_export(
  view_name: :reminder_flow_health,
  action: :inspect,
  privacy: :summary_only)
store.verify_command_flow_evidence_export(export)
store.archive_command_flow_evidence_export(export,
  metadata: { case_id: "ops-1" })
store.command_flow_evidence_archives(
  owner: :reminders,
  view_name: :reminder_flow_health)

store.register(TrackerLog)
store.append(TrackerLog, tracker_id: "sleep", value: 8.5)
store.replay(TrackerLog)
```

Client-backed mode currently supports `register`, `write`, `read`, `append`,
plain `replay`, `replay(partition:)`, `scope`, `on_scope`, declared
one-to-many relation auto-wire, typed `resolve`, `_relations`,
projection descriptor registration, command/effect descriptor registration,
`_projections`, `_commands`, `_effects`, read-only `_scatters`,
`command_policy_decision`, `apply_command`, `command_lifecycle`,
`command_lifecycle_events`, `command_flow`, `command_flow_slice`,
`command_flow_summary`, `command_flow_monitor`,
`register_command_flow_view`, `_command_flow_views`, `command_flow_view`,
`pin_command_flow_view`, `append_command_flow_decision`,
`command_flow_decisions`, `command_flow_decision_review`,
`command_flow_evidence_profile`, `command_flow_evidence_export`,
`export_command_flow_evidence_profile`,
`verify_command_flow_evidence_export`, `archive_command_flow_evidence_export`,
`command_flow_evidence_archives`, `causation_chain`, `lineage`,
`metadata_snapshot`, and `descriptor_snapshot`.
Partition replay lowers through the Ledger replay filter and uses Ledger
partition indexes when served by a Ledger protocol interpreter. Relation support
is v0 and lowers supported one-to-many declarations to Ledger relation
descriptors. Projection, command, and effect support is metadata-only; Ledger
stores descriptors but does not execute app commands or callbacks. Direct
`register_scatter` still requires the embedded Ledger engine path and raises
`NotImplementedError` in client-backed v0.
Provenance support is read-only and compact: Durable Model exposes
`causation_chain`/`lineage`, while Ledger Client `fact_ref` returns metadata
only and does not expose arbitrary `fact_by_id` reads.

Command support has twelve layers: descriptor metadata (`_commands`/`_effects`),
pure `CommandIntent` objects, dry-run `CommandOperationPlan` previews, app-safe
`CommandActivityEvent` summaries, explicit `CommandActivity` audit history
append, explicit `CommandPolicyDecision`, explicit `Store#apply_command`, and
`CommandLifecycle` read models, plus transparent `CommandFlow` orchestration.
`CommandFlowSlice` adds temporal operational read models over command activity;
`CommandFlowMonitorResult` adds deterministic rule evaluation over those slices.
`CommandFlowViewDescriptor` and `CommandFlowView` add named, reusable
operational views that bind filters, horizon defaults, monitor rules, and an
advisory action policy for dashboards and agents.
`CommandFlowViewPin` turns a named view into explicit app-owned pinned decision
evidence with a reproducible horizon and stable app-local receipt shape.
`CommandFlowDecision` and `CommandFlowDecisionReceipt` add explicit app-owned
decision history for persisting pinned or blocked decisions only when requested.
`CommandFlowDecisionReview` adds a compact read model over persisted decisions
with summary metrics and advisory findings.
`CommandFlowEvidenceProfile` bundles view, optional pin, decision review,
decision entries, package-local packet candidates, and logical links for UI,
agents, exports, and future bridge code.
`CommandFlowEvidenceExport` adds deterministic package-local canonicalization,
content hashes, export ids, privacy redactions, and diagnostics for evidence
profiles.
`CommandFlowEvidenceArchive`, `CommandFlowEvidenceArchiveReceipt`, and
`CommandFlowEvidenceExportVerification` add explicit archive persistence and
hash verification for evidence exports.
Future app security infrastructure remains outside this package.
`Store#command_intent`, `Store#command_operation_plan`, and
`Store#command_activity_event` build data only.
`Store#append_command_activity` is the explicit audit persistence step; it
writes only the app-safe summary and returns `CommandActivityReceipt`.
`Store#command_policy_decision` summarizes app-owned capability/review metadata
without mutating storage. `Store#apply_command` is the explicit app-owned
application boundary; it can require or accept a policy decision, applies ready
allowed plans through existing Durable Model `write`/`append` APIs, can
optionally record applied/rejected activity, returns `CommandApplyReceipt`, and
still does not expose fact ids/value hashes or ask Ledger to execute commands.
`Store#command_lifecycle` is a read model over `CommandActivity` history; it
folds intended/planned/rejected/policy_denied/review_required/applied activity
for UI and agents without executing commands or evaluating policy.
`Store#command_flow` is a transparent app-owned orchestrator over the same
pieces. It defaults to `mode: :preview`, generates or preserves a request id,
does not mutate in preview mode, and only applies through `mode: :apply`.
`Store#command_flow_slice` reads `CommandActivity` history over an explicit
temporal horizon (`since:` inclusive lower bound, `as_of:` inclusive observation
horizon), folds requests into app-safe slice items, and exposes counts for
dashboards and agents without raw Ledger facts or command values.
`Store#command_flow_monitor` evaluates explicit plain-data rules against a
slice and returns an app-safe `CommandFlowMonitorResult` with observations,
alerts, and `:ok`/`:warning`/`:critical` status. It does not schedule, notify,
mutate, or add Ledger-side monitor runtime.
`Store#register_command_flow_view` records an app-local descriptor only;
`Store#command_flow_view` evaluates that descriptor by building a slice and
monitor result, returning an app-safe named report without mutation, audit
append, command execution, scheduler, notification delivery, or Ledger protocol
surface. Live views can mark mutation-grade actions as requiring a pinned
horizon; reproducible views are inferred from fixed `as_of`, fixed
`rule_version`, and bounded `fact_scope` unless explicitly declared.
`Store#pin_command_flow_view` evaluates a named view with a fixed
reproducible horizon, checks advisory action policy/capabilities, and returns
`CommandFlowViewPin` evidence with a compact app-local receipt. Blocked actions
return structured errors instead of executing anything.
`Store#append_command_flow_decision` explicitly persists pinned or blocked
decision evidence to `CommandFlowDecision` history and returns an app-safe
`CommandFlowDecisionReceipt`. `Store#command_flow_decisions` replays that
history by owner partition with view/action/actor/status/meaning/receipt and
temporal filters. Decision history is separate from `CommandActivity` and does
not mutate records, execute commands, append command activity, or add Ledger
protocol surface.
`Store#command_flow_decision_review` builds on persisted decision history and
returns `CommandFlowDecisionReview` with counts by status, meaning status,
view, action, actor, missing capabilities, errors, warnings, and simple
rule-derived findings. Decision entries persist both the pin `receipt_id` and
the app-local `decision_receipt_id`; neither is a Ledger fact id.
`Store#command_flow_evidence_profile` packages the current operational view,
optional pin evidence, persisted decision review, compact decision entries,
bridge-ready package-local packet candidates, and stable logical links. It
does not append decisions or command activity, mutate records, execute commands,
or depend on Igniter-Lang observation packets.
`Store#export_command_flow_evidence_profile` exports an existing profile without
re-evaluating it; `Store#command_flow_evidence_export` builds and exports in one
read-only call. Exports support `:app_safe`, `:summary_only`, and
`:hash_payloads` privacy policies, record redactions/diagnostics, and provide
package-local v0 canonical JSON plus SHA256 content hashes and `cfe_...`
export ids.
`Store#verify_command_flow_evidence_export` and
`Store#verify_command_flow_evidence_archive` recompute SHA256 over canonical
JSON and return app-safe verification results. `Store#archive_command_flow_evidence_export`
explicitly persists only verified exports into `CommandFlowEvidenceArchive`
history; invalid exports return a rejected archive receipt and are not appended.
`Store#command_flow_evidence_archives` replays archive history by owner with
view/action/actor/export/hash/privacy/status/meaning and temporal filters.

### Normalized receipts

`write` and `append` return receipt objects carrying mutation metadata.
They delegate unknown methods to the underlying record/event:

```ruby
receipt = store.write(Reminder, key: "r1", title: "Buy milk")
receipt.mutation_intent          # => :record_write
receipt.fact_id                  # => "550e8400-..."
receipt.value_hash               # => "a3b1c2..."
receipt.causation                # => nil (first write) or previous fact id
receipt.title                    # => "Buy milk"  (delegated to Reminder)
receipt.record                   # => #<Reminder ...>

receipt = store.append(TrackerLog, tracker_id: "sleep", value: 8.5)
receipt.mutation_intent          # => :history_append
receipt.timestamp                # => 1714483200.123
receipt.value                    # => 8.5  (delegated to TrackerLog)
receipt.event                    # => #<TrackerLog ...>
```

### Reactive subscriptions

```ruby
store.on_scope(Reminder, :open) do |store_name, payload|
  # fires when the scope cache is invalidated by a write
  puts "#{store_name} changed — refresh your view"
end
```

The subscriber is **not** called on every write — only when the scope cache was
warmed by a prior query and then invalidated by the next write. This is the
lazy-invalidation semantics from igniter-ledger (see [Insights](#pressure--insights)).
Embedded callbacks receive the scope name as the second argument. Client-backed
callbacks subscribe to Ledger client change events for the record store and
receive refreshed records for the declared scope.

---

## Running tests

```bash
# Compile igniter-ledger first (once):
cd ../igniter-ledger
PATH="$HOME/.cargo/bin:$PATH" bundle exec rake compile

# Run the Durable Model suite:
cd ../igniter-durable-model
bundle exec rake spec
```

---

## Pressure & Insights

This section is a living log. Every time the Durable Model layer surfaces a mismatch
or bug in the underlying store, it is recorded here with date, symptom, root cause,
fix, and lesson learned.

---

### [2026-04-30] Float coercion in `ruby_to_json_inner`

**Symptom**: a test storing `TrackerLog#value = 7.0` received Integer `7` back.

**Root cause**: `fact.rs` used `i64::try_convert(val)` to detect numeric type.
Magnus routes this through Ruby's `to_i` coercion protocol, so `Float(7.0).to_i`
returns `7`, and `Float(8.5).to_i` returns `8`.

**Fix** (in `igniter-ledger/ext/igniter_store_native/src/fact.rs`):
```rust
// Before (inaccurate — coerces Float via to_i):
if let Ok(i) = i64::try_convert(val) { return serde_json::json!(i); }
if let Ok(f) = f64::try_convert(val) { return serde_json::json!(f); }

// After (exact Ruby type check):
if let Some(int) = RbInteger::from_value(val) {
    if let Ok(n) = int.to_i64() { return serde_json::json!(n); }
}
if let Some(flt) = RbFloat::from_value(val) {
    return serde_json::json!(flt.to_f64());
}
```

**Lesson**: Magnus's `T::try_convert` goes through Ruby's coercion protocol.
Use `RbInteger::from_value` / `RbFloat::from_value` for exact type dispatch.

---

### [2026-04-30] Lazy scope cache invalidation semantics

**Observation**: `on_scope` consumer does not fire on the first write — only after
the scope cache has been warmed by a query.

**This is intentional**: `ReadCache` removes scope entries on invalidation, but if
the cache is cold there is nothing to remove and therefore no entries → no notifications.

**Implication for Durable Model**: `on_scope` should be documented as
"notification of a warmed-cache change", not "notification of every mutation".
For reacting to every mutation regardless of cache state, a different mechanism
is needed (event bus / WAL tail).

**Open question for igniter-ledger**: should `AccessPath` support an `eager: true`
option that registers the consumer as a point-write listener independent of
cache state?

---

### [2026-04-30] History partition queries

**Capability added**: `partition_key :field_name` on a `History` class; `Store#replay(partition: "value")` filters events by that field.

**Implementation**: partition key lives in the value payload (not in the fact key), so filtering happens at the Ruby layer after `@inner.history(...)` returns all events for the store. No new `AccessPath` registration required.

**Convergence check**: `history_partition_query` check in `StoreConvergenceSidecarContract` passes with `partition_replay_count == 2` and `partition_replay_values == [7.0, 8.5]`.

---

### [2026-04-30] Normalized store receipts (`WriteReceipt` / `AppendReceipt`)

**Capability added**: `Store#write` returns a `WriteReceipt`; `Store#append` returns an `AppendReceipt`. Both carry `mutation_intent`, `fact_id`, `value_hash` and delegate unknown methods to the wrapped record/event.

**Pressure surfaced**: the raw `IgniterStore` returns a `FactData`-like object with `id`/`value_hash`/`causation`/`timestamp`. Wrapping this in typed receipts at the Durable Model layer avoids leaking store internals into application code.

**Next open question** (`pressure.next_question`): `:manifest_generated_record_history_classes` — auto-generate `Record`/`History` classes from a `persistence_manifest` declaration without committing to a final DSL.

---

### [2026-04-30] Manifest-generated Record/History classes

**Capability added**: `Igniter::DurableModel.from_manifest(manifest, store:)` generates an anonymous `Record` or `History` class from an app-local `persistence_manifest` hash. Dispatches on `manifest[:storage][:shape]` (`:store` → `Record`, `:history` → `History`).

```ruby
# From an app-local Igniter contract that declares `persist :reminders`:
klass = Igniter::DurableModel.from_manifest(
  Companion::Contracts::Reminder.persistence_manifest,
  store: :reminders
)
# klass includes Record, has all fields + scopes declared

klass = Igniter::DurableModel.from_manifest(
  Companion::Contracts::TrackerLog.persistence_manifest,
  store: :tracker_logs
)
# klass includes History, has partition_key + all fields
```

**What gets generated from the manifest**:
- Fields: `name` + `default:` (if `attributes[:default]` present)
- Scopes (Record only): `name` + `filters:` (from `attributes[:where]`)
- Partition key (History): `history.key` falling back to `storage.key`

**This gap was resolved immediately**: see next entry.

---

### [2026-04-30] Store name in manifest (`storage.name`)

**Gap resolved**: `persistence_manifest_for` now derives the store name from the contract class name via snake_case + naive pluralisation (`Reminder` → `:reminders`, `TrackerLog` → `:tracker_logs`) and includes it as `storage[:name]`.

```ruby
manifest[:storage]  # => { shape: :store, name: :reminders, key: :id, adapter: :sqlite }
```

**`from_manifest` is now zero-argument for the store name**:

```ruby
klass = Igniter::DurableModel.from_manifest(Contracts::Reminder.persistence_manifest)
klass.store_name  # => :reminders  (from manifest)

klass = Igniter::DurableModel.from_manifest(manifest, store: :override)
klass.store_name  # => :override  (explicit wins)
```

Raises `ArgumentError` if manifest has no `storage.name` and `store:` is not given — keeps the old API path working.

**Next open question** (`pressure.next_question`): `:companion_store_backed_app_flow` — wire `Igniter::DurableModel::Store` into the actual app layer so `persist :reminders` flows through facts/WAL instead of blob-JSON/SQLite.

---

### [2026-04-30] Portable field types

**Capability added**: `field` DSL now accepts `type:` and `values:` kwargs. `from_manifest` mirrors them from `attributes[:type]` and `attributes[:values]` in the manifest descriptor.

```ruby
# Hand-written:
field :status, type: :enum, values: %i[open done], default: :open
field :title,  type: :string
field :score,  type: :float

# Generated from manifest (Article contract with typed fields):
klass = Igniter::DurableModel.from_manifest(Contracts::Article.persistence_manifest)
klass._fields[:status]  # => { type: :enum, values: [:draft, :published, :archived],
                         #      default: :draft }
klass._fields[:title]   # => { type: :string, values: nil, default: nil }
```

**Supported vocabulary** (mirrors app-local `PersistenceFieldTypePlanContract`):
`:string`, `:integer`, `:float`, `:boolean`, `:datetime`, `:enum`, `:json`, `:unspecified` / nil (no-op)

**Annotation only**: `type:` is stored as metadata in `_fields` but does not coerce values during read. Coercion is a separate future concern.

**Evidence**: app-flow sidecar 13/13 stable — `typed_fields_mirrored`, `enum_values_mirrored`, `typed_record_round_trip` all pass.

**Next open question** (`pressure.next_question`): `:mutation_intent_to_app_boundary` — should `WriteReceipt.mutation_intent` feed the app-local action history model directly, or does it need a projection layer?

---

### [2026-04-30] Mutation intent to app boundary

**Capability proven**: `[Architect Supervisor / Codex]` implemented `CompanionReceiptProjectionSidecar` on the app side, proving the projection pattern 12/12 stable.

**Answer**: A projection layer is required. `WriteReceipt` does NOT flow directly to action history. Instead:

```ruby
# Package receipt (internal)
receipt = store.write(reminder_class, ...)
# receipt.mutation_intent  => :record_write
# receipt.fact_id          => "uuid..."      ← NOT exposed upward
# receipt.value_hash       => "blake3..."    ← NOT exposed upward

# App projection (boundary pattern)
app_receipt = {
  kind:              :store_write_receipt,
  source:            :igniter_durable_model_store,
  target:            :reminders,
  subject_id:        "reminder-1",
  status:            :recorded,
  mutation_intent:   receipt.mutation_intent,   # ← preserved
  store_fact_exposed:  false,
  value_hash_exposed:  false
}
# action_event shape → { index:, kind:, subject_id:, status: :recorded }
```

**Boundary**: `fact_id` and `value_hash` are store internals — they stop at the package boundary. `mutation_intent` crosses the boundary because it describes the operation semantics, not the storage internals.

**Evidence**: `companion_receipt_projection_sidecar` 12/12 checks stable (`strategy: :small_app_receipt`).

**Next open question** (`pressure.next_question`): `:index_metadata` — should index declarations from the manifest (unique, composite) be mirrored into the generated class descriptor?

---

### [pending] `nil` vs absent field semantics on read

**Hypothesis** (untested): if a field was not stored in the value hash (e.g. an
optional field added after the first writes), `Record#initialize` applies the
`default:` from the declaration. But if `nil` was explicitly written, `nil` is
returned rather than the default. The distinction between *absent* and *explicitly nil*
is not currently modelled. Worth testing and potentially encoding as a separate concept.

---

### [pending] Nested Hash values

The current DSL has no nested type declarations. For example:

```ruby
field :address  # { city: "Moscow", zip: "101000" }
```

After a round-trip through igniter-ledger the keys are Symbols (`:city`, `:zip`).
This is correct. But there is no way to declare the structure of the nested object.
Candidate for a future DSL addition: `embedded :address do ... end`.

---

### [pending] Convergence with `examples/application/companion`

The current `CompanionStore` in `examples/application/companion/services/companion_store.rb`
uses blob-JSON over SQLite. The target path:

```
PersistenceSketchPack (DSL: persist/history/field/scope)
  → generates Record/History classes
  → stores via Igniter::DurableModel::Store
  → backed by Igniter::Ledger::LedgerStore (facts + WAL)
```

When the first real `persist :reminders` flows through this stack end-to-end,
the two tunnels will meet.
