# Companion / Store Convergence

Status date: 2026-05-01.
Role: compact cross-track note for `[Architect Supervisor / Codex]`.
Scope: synchronization between the app-local Companion persistence proof,
`packages/igniter-companion`, and `packages/igniter-ledger`.

## Claim

These tracks are one system seen from three levels:

```text
examples/application/companion
  -> contract-declared capability manifests, commands, relations, materializer

packages/igniter-companion
  -> typed application Record/History facade over store primitives

packages/igniter-ledger
  -> immutable facts, WAL, replay, cache, access paths, time-travel
```

The convergence point is not a bigger `Store` facade. It is the moment a
contract manifest can generate or bind a typed `Record` / `History` class, route
its normalized mutation intent through `Igniter::Companion::Store`, and persist
as facts through `Igniter::Store::IgniterStore`.

## Current Alignment

- app-local Companion proves vocabulary and boundaries:
  `persist`, `history`, `field`, `index`, `scope`, `command`, relations,
  storage plans, access paths, and typed effect intent descriptors
- `igniter-companion` proves the intended developer surface:
  typed records, append-only histories, scopes, replay, time-travel, and
  scope-level invalidation callbacks
- `igniter-ledger` proves the substrate:
  immutable content-addressed facts, causation chains, current reads,
  time-travel reads, access path registry, read cache invalidation, and WAL
  replay

## Current Sidecar Proof

Companion now exposes a tiny convergence sidecar:

- `/setup/store-convergence-sidecar`
- `/setup/store-convergence-sidecar.json`
- `/setup/companion-store-app-flow-sidecar`
- `/setup/companion-store-app-flow-sidecar.json`
- `/setup/companion-index-metadata-sidecar`
- `/setup/companion-index-metadata-sidecar.json`
- `/setup/companion-store-projection-metadata-sidecar`
- `/setup/companion-store-projection-metadata-sidecar.json`
- `/setup/companion-store-schema-graph-metadata-sidecar`
- `/setup/companion-store-schema-graph-metadata-sidecar.json`
- `/setup/companion-receipt-projection-sidecar`
- `/setup/companion-receipt-projection-sidecar.json`
- `/setup/companion-store-server-topology-sidecar`
- `/setup/companion-store-server-topology-sidecar.json`

This packet is report-only and ephemeral. It creates an in-memory
`Igniter::Companion::Store`, defines package-level typed classes for one
`Reminder` record and one `TrackerLog` history, and exercises the path into
`Igniter::Store::IgniterStore`.

Proved:

- `Igniter::Companion.from_manifest` now generates typed package Record/History
  classes from app-local persistence manifests
- `Reminder` contract manifest generates the typed package Record class
- Record write/read/scope works through `Igniter::Companion::Store`
- Record time-travel read returns the earlier `:open` state
- Record causation chain has two facts
- Record writes now return normalized `WriteReceipt` data with fact metadata
  and delegation back to the typed record
- `TrackerLog` contract manifest generates the typed package History class
- float values round-trip as `[7.0, 8.5]`
- `TrackerLog` declares `partition_key :tracker_id`
- `Store#replay(partition: "sleep")` filters the append-only history stream by
  the declared partition key
- history appends now return normalized `AppendReceipt` data with fact metadata
  and delegation back to the typed event
- facts expose receipt data through `fact_id`, `value_hash`, and `timestamp`
- app-local manifests now expose `storage.name`, so `from_manifest(manifest)`
  can bind the package store/history name without a `store:` override
- the app-flow sidecar proves one app-pattern `Reminder` write/read/scope cycle
  through `Igniter::Companion::Store` and returns a normalized write receipt
- the index metadata sidecar proves app manifests can normalize
  `index :status` into portable metadata and explain scope coverage without
  promising SQL indexes; the package gap is now closed by generated
  `Record._indexes` metadata
- the receipt projection sidecar proves package receipts should feed app action
  history through a small app receipt projection, not direct receipt consumption
- the store-server topology sidecar proves the app/server boundary shape:
  app computes contracts, LedgerServer hosts durable fact projection, network
  transport is backend swap, and native wire deserialization is the explicit gap
- the same topology packet now tracks the new operational surface:
  `ServerConfig`, `ServerLogger`, `SubscriptionRegistry`, `wait_until_ready`,
  graceful drain, `stats`, and `subscribe/fact_written` push delivery
- projection descriptors now mirror through the package facade:
  `Igniter::Companion::Store#register_projection`, `_projections`, and Store
  `SchemaGraph#projection_snapshot` close the `_projections` metadata gap
- Store now has the first reactive derivation substrate:
  `DerivationRule`, derivation registry/snapshot, and `lineage(store:, key:)`
  with causation proof hash
- the packet does not mutate main Companion state or replace the current app
  backend

## Pressure Points

1. App-local Companion has richer manifests than `igniter-companion` classes.
   The sidecar can now generate `field`, `scope`, `partition_key`, and
   metadata-only `index` descriptors from manifests through the package facade,
   but the facade still does not consume the full descriptor vocabulary:
   command metadata, relation metadata, effect metadata, or manifest export.

2. `igniter-ledger` has facts and access paths, but command intent still lives
   above it. R2d now says commands should keep lowering to `mutation_intent`,
   while future storage effects are typed as `store_write` / `store_append`.

3. Reactive semantics are intentionally cache-invalidation based. This is useful
   for view refresh, but not enough for "every mutation" subscribers. That
   pressure belongs in store research as either WAL tail, event bus, or explicit
   eager access path listeners.

4. History append uses generated fact keys. App-level `history key:
   :tracker_id` now has a first package answer in `igniter-companion`:
   `partition_key :tracker_id` plus `Store#replay(partition:)`. The first
   implementation filters in Ruby after `IgniterStore#history`; future store
   work can decide whether this becomes an indexed access path.

5. Normalized receipts now exist at the package facade and the app-local answer
   is projection: action history receives a small app receipt, not substrate
   receipt internals.

6. Index descriptors are present in app manifests and now mirror into generated
   package Records as metadata-only `_indexes`. This closes the first portable
   descriptor gap without promising SQL indexes, migrations, or planner changes.

7. Blob-JSON SQLite in the app remains a useful POC backend, but the next true
   convergence proof should be a tiny isolated adapter slice, not a full
   Companion migration.

## Recommendation Requests

For `igniter-ledger` research:

- What is the minimal fact descriptor needed to represent `Store[T]` versus
  `History[T]` without importing app-level DSL concepts?
- Should append-only histories promote partition filtering to first-class store
  access paths, or keep first-pass Ruby-layer filtering?
- Should "every mutation" observation be modeled as WAL tail, event bus, eager
  access path, or a separate `History[StoreEvent]`?
- How should typed effect intent map to facts: direct `write/append`, command
  receipt fact, normalized facade receipt, or all three?

For `igniter-companion` research:

- `manifest_generated_record_history_classes`, `store_name_in_manifest`,
  `companion_store_backed_app_flow`, `portable_field_types`,
  `mutation_intent_to_app_boundary`, `index_metadata`, `command_metadata`, and
  `effect_metadata`, and `relation_metadata` are resolved as report-only
  proofs. Next package-facade pressure is `store_projection_metadata`.
- Should `storage.name` remain the canonical capability identity, or should it
  later split into separate package store name and app capability name?
- Which app-local descriptors should be mirrored first: field type, scope,
  index, or command metadata?
- Can `Igniter::Companion::Store` receipts be shaped into the app-local
  `mutation_intent -> app boundary -> action history` model without leaking
  substrate details?

For app-local Companion:

- Keep R2a-R2d as the read-before-write ladder.
- Do not replace the SQLite JSON backend yet.
- The tiny sidecar proof is now present and updated for partition replay plus
  normalized receipts.
- The app-flow sidecar is sufficient to close `companion_store_backed_app_flow`
  as an isolated proof, not as an app backend migration.
- Portable field types are mirrored into generated package classes as
  annotation-only metadata (`type`, `values`), without coercion.
- Package write receipts feed action history through a small app receipt
  projection. Store internals stay evidence-only.
- `index_metadata` now has a closed app-local pressure packet: manifests
  normalize indexes, explain scope coverage, and generated package Records
  expose metadata-only `_indexes`.
- `command_metadata` now has a closed app-local pressure packet: manifest
  commands mirror into generated package Records as metadata-only `_commands`
  and preserve `command -> mutation_intent -> app boundary`.
- `effect_metadata` now has a closed app-local pressure packet: generated
  package Records derive metadata-only `_effects` from `_commands`, preserving
  `effect -> store_write/store_append intent -> app boundary` without store-side
  execution.
- `relation_metadata` now has a closed app-local pressure packet: app-local
  relation descriptors mirror into generated package Records as metadata-only
  `_relations`, preserving relation health/reporting above Store[T]/History[T].
- `store_projection_metadata` now has a closed pressure packet: Companion
  projects existing `projection` manifests into metadata-only projection
  descriptors (`reads`, `relations`, consumer hints), and the package facade
  exposes `_projections`.
- `store_schema_graph_metadata_snapshot` is now closed as Store-side metadata
  evidence: app scope access paths lower into `Igniter::Store::SchemaGraph` and
  `metadata_snapshot` preserves store/scope/filter routing without exposing
  callback bodies or promising a query planner.
- LedgerServer topology now has an app-local pressure packet. It does not execute
  network transport in the app POC; it records `LedgerNetworkBackend`/LedgerServer as a
  backend-swap topology and keeps `native_wire_deserialization` as package gap.
- Next package-facing pressure is `reactive_derivation`; subscription delivery
  semantics stay queued behind native wire/runtime readiness.

## Non-Goals

- no core graph nodes from this note
- no public API promise for `persist`, `history`, `field`, `index`, `scope`, or
  `command`
- no migration of the full Companion app to fact storage yet
- no SQL generation or migration execution
- no materializer write/git/test/restart capabilities

## Handoff

```text
[Architect Supervisor / Codex]
Track: companion-store-convergence
Status: alignment note plus tiny sidecar proof updated with partition replay
and normalized receipts.
[D] App-local Companion owns vocabulary pressure; igniter-companion owns typed
developer surface; igniter-ledger owns fact substrate.
[D] Current bridge proves manifest-generated Record/History bindings over
Igniter::Companion::Store as a tiny sidecar proof, including partition replay,
normalized receipts, relation metadata, and app-local projection descriptor
shape plus Store schema-graph metadata evidence.
[R] Preserve `persist -> Store[T]`, `history -> History[T]`, and command ->
mutation_intent -> app boundary.
[R] Do not migrate full Companion storage or promote API from this note alone.
[S] `/setup/store-convergence-sidecar.json` proves record/history fact-store
round trip, partition replay, and normalized receipt metadata.
[S] `/setup/companion-store-projection-metadata-sidecar.json` proves
projection descriptor shape and reports package_gap=:closed for `_projections`.
[S] `/setup/companion-store-schema-graph-metadata-sidecar.json` proves app
scope paths lower to Store `SchemaGraph#metadata_snapshot`.
[S] Store package now exposes derivation metadata and lineage proof primitives.
Next: prove reactive derivation from app projection/read-model intent without
query planner, adapter projection execution, or app backend migration.
```
