# Igniter Ledger Progress Summary

Status date: 2026-05-03.
Audience: Architect Supervisor, Package Agent, Research.
Scope: compact checkpoint for `packages/igniter-ledger` and its pressure on
`igniter-companion` / Companion.

## Read Model

```text
Store[T] record write
  -> immutable Fact(id, store, key, value, value_hash, causation,
     transaction_time, valid_time, producer, derivation)
  -> FactLog append
  -> current read / time-travel read
  -> scope query via registered AccessPath
  -> scope cache invalidation + scope-aware consumers

History[T] append
  -> immutable Fact(key=uuid, value=event)
  -> replay all / replay partition
  -> partition index when partition_key is known

File backend
  -> CRC32-framed WAL
  -> snapshot checkpoint/replay support

Network backend
  -> CRC32-framed request/response transport
  -> LedgerServer owns durable facts
  -> clients replay facts and rebuild local read indices
  -> native-aware Fact.from_h deserialisation path
```

## What Is Strong Now

- Facts are immutable and content-addressed by `value_hash`.
- Causation uses previous fact `id`, not `value_hash`, so repeated identical
  writes still produce an unambiguous temporal chain.
- Current reads and time-travel reads are structural features, not app-local
  patches.
- Scope access paths are registered ahead of data and backed by a lazy
  materialized scope index.
- Scope invalidation is membership-aware: unchanged scope membership suppresses
  false-positive consumers.
- History partition replay is backed by a lazy partition index and maintained on
  append when `partition_key:` is passed.
- Time-travel cache entries have an LRU cap; current-state cache entries remain
  invalidation-driven.
- Schema version coercion exists as a read-path hook; raw facts are never
  mutated.
- `SchemaGraph#metadata_snapshot` exposes compact access-path routing metadata
  without leaking callback bodies or promising a query planner.
- `SchemaGraph` now also registers projection descriptors and derivation rules
  as inspectable metadata, still without becoming a query planner.
- `ProjectionPath` mirrors app projection descriptors into Store-side graph
  vocabulary.
- `DerivationRule` proves the first reactive derivation shape with a lineage
  API and causation proof hash.
- `ScatterRule` adds partitioned 1-source to 1-index-entry derivations for
  relation/read-model indexes, with cycle protection separate from gather rules.
- `RetentionPolicy` and `compact` add first hot-log lifecycle control:
  permanent, ephemeral, and rolling-window retention with compaction receipts.
- `RelationRule` adds the first named relation primitive over Store facts:
  `register_relation`, auto scatter index `__rel_<name>`, `resolve`, and
  `relation_snapshot`.
- `Fact` now carries canonical Ledger metadata in Ruby and native modes:
  `transaction_time`, nullable `valid_time`, `producer`, and inline
  `derivation`; `timestamp` and `term` remain transitional aliases.
- `Protocol::Interpreter` (OP1/OP2) opens an ecosystem-facing protocol surface:
  descriptor packet import (7 kinds), content-addressed dedup, write receipts,
  protocol-level `write`/`write_fact`/`read`/`query(where:)`/`resolve`, and
  unified `metadata_snapshot` covering all registered graph artifacts.
- File durability moved from old JSONL POC thinking to CRC32-framed WAL.
- Snapshot checkpoint/replay exists across the current Ruby/native-aware package
  surface.
- `LedgerNetworkBackend` + `LedgerServer` prove the first transport abstraction:
  app/client code can talk to a remote durable fact host through the same
  backend interface.
- `WireProtocol` is now shared framing vocabulary for WAL and network transport.
- The server model keeps contract computation in the app and moves durable fact
  projection to the store server.

## Compaction Lifecycle Vocabulary

One lifecycle, three verbs. Future slices must not introduce competing terms.

```text
compact
  semantic lifecycle verb
  reduce retained detail while preserving truth/proof
  executor: IgniterStore#compact (retention policy)
            AvailabilityBoundaryLedger#compact_boundary (semantic boundary)

prune
  exact fact-level executor
  remove known fact ids from the hot logical log
  executor: IgniterStore#prune_fact_ids
            (called internally by boundary purge and retention compact)

purge
  physical storage executor
  remove whole storage artifacts such as sealed segments
  executor: SegmentedFileBackend#purge! (segment-level)
            AvailabilityBoundaryLedger#purge_cleanup_execution (boundary physical detail)
```

Rule: no new deletion/compaction API should bypass this lifecycle.
Executors remain specialized; plans and receipts normalize into one inspectable
activity stream via `store.compaction_activity` /
`ledger.compaction_activity`.

## Current Test Signal

- `packages/igniter-ledger`: 1171 examples, 0 failures (as of 2026-05-04, includes Compaction Activity Protocol Surface v0 + Compaction Lifecycle Unification v0 + Physical Purge Barrier v0).
- `packages/igniter-companion`: 89 examples, 0 failures.

## Architecture Meaning

`igniter-ledger` is now best understood as the hot fact engine:

- not an ORM
- not a DB adapter abstraction
- not the public contract persistence API
- yes: append-only truth, time travel, causation, access paths, cache
  invalidation, hot/cold sync foundation, retention/compaction, and now a first
  store-server transport path

`igniter-companion` is the typed facade:

- maps app/contract manifests to Record/History classes
- turns raw store facts into typed records/events and normalized receipts
- should keep package receipts from leaking fact internals into app history

Companion app-local proof is the product pressure:

- asks for manifest-generated classes
- asks for portable field metadata
- asks for index metadata
- asks later for command/effect metadata and relation metadata

## Important Drift Note

Older thread references to `docs/research/contract-native-store-poc.md` are
historical context only. The current package README and specs in
`packages/igniter-ledger/docs/` are the canonical Store POC state.

## Next Pressure

Open protocol slices completed:

```text
OP1 — Descriptor Packet Import
  -> Protocol::Interpreter dispatches by kind: (7 handler classes)
  -> Content-addressed dedup (SHA256 fingerprint)
  -> Named helpers: register_store / register_history / register_access_path /
     register_relation / register_projection / register_derivation /
     register_subscription
  -> Protocol-level write / write_fact / read / query(where:) / resolve
  -> Receipt contract: :accepted | :rejected | :deduplicated + write receipts

OP2 — Metadata Export
  -> Protocol::Interpreter#metadata_snapshot returns unified snapshot:
     stores, histories, access_paths, relations, projections, derivations,
     scatters, subscriptions, retention (schema_version: 1)
  -> descriptor_snapshot for raw store/history/subscription descriptors
  -> Companion, LedgerServer, and visual tools consume one endpoint

OP3 — Wire Envelope
  -> Protocol::WireEnvelope dispatches op envelope hashes to Interpreter
  -> Operations: register_descriptor / write / write_fact / read / query /
     resolve / metadata_snapshot / descriptor_snapshot
  -> Response envelope: { protocol:, schema_version:, request_id:, status:, result: }
  -> Error safety net: unexpected raises → error response (never leaks exceptions)
  -> Interpreter#wire (memoized) + Interpreter#dispatch convenience shorthand
  -> Pure Ruby — no I/O; LedgerServer feeds deserialized hashes in,
     ships serialized responses out (framing stays in WireProtocol)

OP4 — Sync Hub Profile
  -> SyncProfile value object: schema_version, kind, generated_at, cursor,
     descriptors, facts, retention, compaction_receipts, subscription_checkpoints
  -> SyncProfile#full? / incremental? / fact_count / next_cursor
  -> Cursor: { kind: :timestamp, value: Float } — hub persists and sends back
     on next sync to receive only new facts (incremental delta mode)
  -> Interpreter#sync_hub_profile(as_of:, cursor:, stores:) — full or incremental
  -> Interpreter#replay(from:, to:, filter:) — WAL replay as fact packet array
  -> IgniterStore#fact_log_all(since:, as_of:) — time-bounded log access
  -> WireEnvelope: :sync_hub_profile and :replay ops added
  -> serialize_fact helper: full fact → protocol fact packet hash
  -> All four open-protocol slices (OP1–OP4) now implemented

Companion Protocol Adoption
  -> Companion::Store#register emits :store or :history descriptor via
     @inner.register_descriptor on every new schema class registration
  -> Record classes (respond_to?(:_scopes)) → :store descriptor with fields,
     capabilities, and producer: { system: :igniter_companion }
  -> History classes → :history descriptor with partition_key as key:
  -> Companion::Store#metadata_snapshot delegates to @inner.protocol.metadata_snapshot
  -> Companion::Store#descriptor_snapshot delegates to @inner.protocol.descriptor_snapshot
  -> metadata_snapshot[:stores] / [:histories] now reflect all companion-managed schemas
  -> Access paths still registered via direct API (preserves filter semantics)
  -> 89 companion specs, 0 failures
```

Store-side pressure after index metadata:

- keep `SchemaGraph#metadata_snapshot` as metadata evidence, not a planner API
- decide whether index descriptors remain facade metadata or become explicit
  `AccessPath` metadata
- use `/setup/companion-store-server-topology-sidecar.json` as app-local pressure
  when discussing LedgerServer topology from Companion
- LedgerServer has moved from transport proof to operational proof:
  `ServerConfig`, `ServerLogger`, `SubscriptionRegistry`,
  `igniter-ledger-server`, `wait_until_ready`, graceful drain, `stats`, and
  `subscribe/fact_written`; Companion should treat this as lifecycle/delivery
  capability, not as a contract-logic RPC surface
- finish true native fact reconstruction if stable `id` / `timestamp` fidelity
  becomes required over the network
- keep `LedgerNetworkBackend` as a transport/backend swap, not as RPC for contract
  logic
- keep PostgreSQL sync hub as cold/async circuit, not write-path dependency
