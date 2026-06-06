# Durable Model Current Status Summary

Status date: 2026-05-02.
Role: compact handoff for `[Architect Supervisor / Codex]`.
Scope: Durable Model app-local proof only; no public persistence API promise.
The physical package is now `igniter-durable-model`; the canonical Ruby
namespace is `Igniter::DurableModel`, with `Igniter::Companion` retained as
compatibility.

## Current Claim

Companion now proves a contract-declared persistence capability model where:

- durable shapes are contracts (`persist`, `history`, fields, metadata)
- behavior is graph-owned command/result/mutation intent
- side effects happen only at the app/store boundary
- setup/read endpoints remain inspectable and mostly side-effect-free
- materializer capability flow is modeled before any real capability is granted

## Proven Shape

Current manifest scale:

- records: 6
- histories: 6
- projections: 5
- command groups: 5
- relations: 2
- total capabilities: 19

Core validated path:

```text
persist -> Store[T]
history -> History[T]
storage.shape=:store/:history -> canonical manifest descriptor
relation -> typed manifest edge
relation_descriptor -> source/target storage shapes + report-only enforcement
storage_plan_sketch -> report-only table/column/index/scope lowering candidates
storage_plan_health -> drift check for non-executing storage-plan shape
storage_migration_plan -> review-only storage-plan diff candidates
storage_migration_plan_health -> drift check for non-executing migration plan
field_type_plan -> report-only validation of field descriptors + samples
field_type_health -> drift check for field/type validation boundaries
relation_type_plan -> report-only join field type compatibility
relation_type_health -> drift check for non-enforcing relation type plan
access_path_plan -> report-only store_read descriptor sketch
access_path_health -> drift check for non-executing access path plan
effect_intent_plan -> report-only store_write/store_append descriptor sketch
effect_intent_health -> drift check for app-boundary typed effect intent
store_convergence_sidecar -> manifest-generated Record/History over fact store
companion_store_app_flow_sidecar -> isolated app-pattern Store write + receipt proof
companion_index_metadata_sidecar -> manifest index descriptors + closed package _indexes metadata
companion_command_metadata_sidecar -> manifest command descriptors + closed package _commands metadata
companion_effect_metadata_sidecar -> derived effect descriptors + closed package _effects metadata
companion_relation_metadata_sidecar -> relation descriptors + closed package _relations metadata
companion_store_projection_metadata_sidecar -> projection descriptors + closed package _projections gap
companion_store_schema_graph_metadata_sidecar -> app scope paths + closed Store SchemaGraph metadata snapshot
companion_receipt_projection_sidecar -> package receipt -> action history projection proof
companion_store_server_topology_sidecar -> StoreServer topology/lifecycle/push + native wire gap proof
store_reactive_derivation -> package DerivationRule/ScatterRule + CompanionStore _scatters facade
store_retention_compaction -> package RetentionPolicy + explicit compaction receipts, app policy not proven yet
relation_rule_dsl -> Store RelationRule primitive + Companion auto-wire/typed resolve/as_of resolve
store_open_protocol -> OP1/OP2/OP3/OP4 descriptor import, metadata export, wire envelope, sync profile
companion_protocol_adoption -> Companion::Store#register emits :store/:history descriptors;
  metadata_snapshot / descriptor_snapshot delegate to @inner.protocol (OP2 surface)
performance_signal -> setup packet recomputation needs memoization/snapshot
command -> normalized operation intent
operation_descriptor -> explicit target shape + mutation boundary
materializer_status.descriptor -> review-only lifecycle + no capability grants
materializer_status_descriptor_health -> report-only no-grant/no-execution guard
setup_health.descriptor -> report-only summary over readiness + guardrails
setup_handoff.descriptor -> compact context rotation packet
setup_handoff_lifecycle -> read-only lifecycle map over handoff acceptance
setup_handoff_lifecycle_health -> drift check without setup_health cycle
setup_handoff_supervision -> single agent context packet over handoff lifecycle
setup_handoff_packet_registry -> read-only index of setup/handoff packet surface
setup_handoff_extraction_sketch -> landing-zone map without package promise
setup_handoff_promotion_readiness -> explicit blocked signal for package/API promotion
setup_handoff_digest -> compact text diagram and next-read summary (.json + .txt)
setup_handoff_next_scope -> supervised backlog packet, not execution
setup_handoff_next_scope_health -> drift check for supervised backlog shape
app boundary -> explicit mutation application
projection -> graph-owned read model
```

## Materializer Vertical

The latest work built a full review-only materializer lifecycle:

```text
WizardTypeSpec
-> materialization plan
-> parity
-> infrastructure loop health
-> gate
-> preflight
-> runbook
-> receipt
-> attempt command
-> explicit attempt POST
-> attempt history
-> audit trail
-> supervision
-> approval policy
-> approval receipt
-> approval history shape
-> approval command
-> explicit approval POST
-> approval audit trail
-> supervision with attempt + approval audit
-> materializer_status descriptor with review-only/no-grant boundary
-> materializer_status_descriptor_health report-only guard
```

Important boundary:

- approval/policy/receipt/history are data and audit shapes
- `applies_capabilities` remains false
- no write/git/test/restart capability is granted by setup reads
- explicit write paths exist only for recording blocked materializer attempts
  and approval receipts
- the compact materializer status packet now has its own descriptor, but that
  descriptor is only inspection metadata
- descriptor health now checks that the status packet still refuses capability
  grants and execution

## Most Important Insight

The system is becoming self-supporting:
contracts describe durable types, validate their own infrastructure, produce
review packets, define command intents, and expose audit trails for the process
that may later materialize contracts.

That fractal shape looks healthy, but it must stay app-local until the API
surface is smaller and the lowerings to `Store[T]` / `History[T]` are clearer.

Performance signal: individual persistence packets are fast, but aggregate
`/setup` is slow because it recomputes nested setup/handoff/materializer packets
many times and renders a large inspected hash. See
[Companion Contract Performance Signal](./performance.md).

## Landing Zone

Persistence has enough signal to reserve a future home, but not enough to split
now.

Recommended path:

- current: Companion app-local proof
- first extraction: contract vocabulary/descriptors toward `igniter-extensions`
- first runtime host extraction: registry, adapters, setup/readiness,
  app-boundary writes, and materializer review flows toward
  `igniter-application`
- later, if repeated evidence appears: create `igniter-persistence`

Avoid `igniter-data` for this capability. It is too broad; the sharper concept
is durable `Store[T]`, append-only `History[T]`, typed relations, command
intents, materialization, and audit.

## Discussion Summary

Fields do not map to SQL tables yet. They map to manifest descriptors,
generated app-local APIs, payload normalization, and projections. The current
SQLite backend stores one JSON state payload in `companion_state`.

Storage planning is now sketched, not executed. `/setup/storage-plan.json`
derives table/storage names, key candidates, column candidates, adapter type
mapping candidates, indexes, scopes, and append-only history table candidates
from the manifest while keeping `schema_changes_allowed: false` and
`sql_generation_allowed: false`.
`/setup/storage-plan-health.json` verifies that this storage sketch remains
report-only, no-gate/no-grant, non-SQL-generating, and non-schema-changing.
`/setup/storage-migration-plan.json` compares storage-plan descriptors and emits
review-only migration candidates for additive/destructive/ambiguous storage
changes while keeping migration execution and SQL generation disabled.
`/setup/storage-migration-plan-health.json` verifies that R2 reports and
candidates keep review-only/no-execution/no-SQL boundaries.
`/setup/field-type-plan.json` is the R2a field/type validation report: it
checks descriptor vocabulary, defaults, enum values, JSON fields, datetime
values, required keys, and seeded payload shape while preserving
`persist -> Store[T]` and `history -> History[T]`.
`/setup/field-type-health.json` verifies that this type-validation packet stays
report-only, no-gate/no-grant, non-SQL, non-schema-changing, and non-materializing.
`/setup/relation-type-plan.json` is the R2b relation type compatibility report:
it checks join field descriptors for `Relation[Store[A], History[B]]` edges
without generating FKs or enforcing relations.
`/setup/relation-type-health.json` verifies that relation type compatibility
stays report-only, non-enforcing, and capability-free.
`/setup/access-path-plan.json` is the R2c access path sketch: it reports
record/history/relation read descriptors, key bindings, scope/filter sources,
cache/coalesce hints, and projection reactive consumer hints without creating a
StoreRead graph node or runtime planner.
`/setup/access-path-health.json` verifies that access-path metadata remains
report-only, no-gate/no-grant, non-mutating, and non-executing.
`/setup/effect-intent-plan.json` is the R2d typed effect intent sketch: it maps
existing command mutation intents to future `store_write` / `store_append`
descriptors while keeping `command_still_lowers_to: :mutation_intent`.
`/setup/effect-intent-health.json` verifies that typed effects remain
report-only, app-boundary-only, non-Saga, and do not create StoreWrite or
StoreAppend runtime nodes.
`/setup/store-convergence-sidecar.json` is the first tiny convergence proof
between app-local manifests, `igniter-durable-model`, and `igniter-ledger`: one
`Reminder` typed Record and one `TrackerLog` typed History flow through
`Igniter::Companion::Store` into immutable facts without replacing the current
Companion backend. It now generates the package Record/History classes from
the app-local contract manifests and includes normalized `WriteReceipt` /
`AppendReceipt` metadata plus `TrackerLog` partition replay via
`partition_key :tracker_id`.

Migrations are review-only. Current planning has two lanes: spec-history field
diffs and storage-plan descriptor diffs. There is no migration generator,
runner, DB alteration, backfill, or destructive apply path.

Materialization is modeled, not executed. The system can plan static contracts,
check parity, build a gated runbook, and persist attempt/approval receipts, but
it cannot write files, run git/tests/restart, or grant capabilities.

Reference: [Contract Persistence Roadmap](../../../playgrounds/docs/research/contract-persistence-roadmap.md) (archived — roadmap fully walked as of 2026-05-02).

## Current Boundary

Do not promote yet:

- `persist` / `history` / `field` / `index` / `scope` / `command` to core
- materializer execution
- migration generator
- DB planner
- relation enforcement
- approval capability grants
- dynamic runtime contract execution

Do preserve:

- `persist -> Store[T]`
- `history -> History[T]`
- `WizardTypeSpec ~= Store[ContractSpec]`
- `WizardTypeSpecChange ~= History[ContractSpecChange]`
- `MaterializerAttempt ~= History[MaterializerAttempt]`
- `MaterializerApproval ~= History[MaterializerApproval]`

## Next Reversible Slice

Best next move:

- use manifest glossary health as the guardrail for the next implementation
  slice
- use `/setup/health.json` as the compact current-state packet before deeper
  changes
- use `/setup/storage-plan-health.json` before treating storage-plan output as
  valid R1 evidence
- use `/setup/storage-migration-plan.json` when discussing R2 storage-plan
  diffs; it is review-only and has no execution path
- use `/setup/storage-migration-plan-health.json` before treating R2 migration
  candidates as stable evidence
- use `/setup/field-type-plan.json` before widening field metadata, relation
  type checks, access paths, or materializer dry-run output
- use `/setup/field-type-health.json` before treating R2a type validation as
  stable evidence
- use `/setup/relation-type-plan.json` before changing relation joins,
  projections, access paths, or future FK/migration discussions
- use `/setup/relation-type-health.json` before treating R2b relation type
  compatibility as stable evidence
- use `/setup/access-path-plan.json` before discussing future `store_read`
  graph dependencies, cache plans, reactive consumers, or typed effect intents
- use `/setup/access-path-health.json` before treating R2c access-path
  descriptors as stable evidence
- use `/setup/effect-intent-plan.json` before discussing future `store_write`,
  `store_append`, Saga, or effect-node semantics
- use `/setup/effect-intent-health.json` before treating R2d typed effect
  descriptors as stable evidence
- use `/setup/store-convergence-sidecar.json` before discussing package-level
  store adapter slices, fact receipts, partition replay, or package facade
  descriptor mirroring
- use `/setup/companion-store-projection-metadata-sidecar.json` before
  discussing projection/read-model descriptor mirroring; it is stable
  app-local pressure and now reports package_gap=:closed for `_projections`
- use `/setup/companion-store-schema-graph-metadata-sidecar.json` before
  discussing Store-side access-path metadata; it proves app scope paths lower to
  `SchemaGraph#metadata_snapshot` without query planner or backend migration
- use Store derivation/scatter/lineage specs plus `CompanionStore#_scatters`
  before treating relation rules as app-proven; the substrate/facade exists,
  but relation DSL lowering is still the next slice
- use `/setup/handoff.json` as the first read after context rotation
- use `/setup/handoff/digest.txt` as the compact human handoff, or
  `/setup/handoff/digest.json` as the structured agent map before
  following the deeper packet list
- use `/setup/handoff/next-scope.json` as the supervised backlog packet before
  treating any candidate as the current slice
- use `/setup/handoff/next-scope-health.json` as the drift check that backlog
  metadata is still report-only and capability-free
- use `/setup/handoff/lifecycle.json` as the compact lifecycle map before
  reading individual acceptance packets
- use `/setup/handoff/lifecycle-health.json` as the lifecycle drift check; it
  intentionally stays outside `setup_health` to avoid a cyclic packet graph
- use `/setup/handoff/supervision.json` when an agent needs one compact packet
  with lifecycle stage, health signals, packet refs, and next action
- use `/setup/handoff/packet-registry.json` when an agent needs the indexed
  setup packet surface plus explicit receipt POST paths
- use `/setup/handoff/extraction-sketch.json` when an agent needs the
  app-local/extensions/application/future-persistence placement map
- use `/setup/handoff/promotion-readiness.json` when an agent needs the current
  blocker list for package/API promotion
- follow its `reading_order` through both handoff acceptance packets before
  deciding that the materializer lifecycle advanced
- follow its `document_rotation` block before reading long thread history
- keep its `architecture_constraints` intact before implementing a new slice
- use `next_scope` through `/setup/handoff/next-scope.json` as a supervised
  backlog, not an execution command
- use its embedded `acceptance_criteria` before calling a small slice complete
- use `/setup/handoff/acceptance.json` to observe acceptance before/after an
  explicit app-boundary action
- `POST /setup/handoff/acceptance/record` is only an explicit alias for the
  same materializer attempt receipt path
- use `/setup/handoff/approval-acceptance.json` to observe the follow-up
  approval receipt as audit data, not as a capability grant
- choose the next term only after the current glossary remains stable
- continue avoiding execution and capability grant controls

Acceptance:

- another agent can read manifest terms without reconstructing history
- glossary health remains stable
- materializer status descriptor health remains stable
- setup health remains stable or reports review items without blocking runtime
- setup health descriptor remains report-only and does not gate runtime
- setup handoff remains read-only and points to the current reading order
- setup handoff keeps public/private document rotation compact
- setup handoff preserves app-local/no-public-API/no-execution constraints
- setup handoff keeps next scope small, reversible, and app-local
- setup handoff defines acceptance without creating a runtime gate
- setup handoff acceptance remains report-only and pending until explicit POST
- setup handoff approval acceptance remains report-only, and satisfaction still
  requires `applied_count: 0`
- `/setup` surfaces glossary health without making readiness stricter
- no setup/read endpoint mutates durable state

Reference: [Companion Persistence Manifest Glossary](./manifest-glossary.md).
