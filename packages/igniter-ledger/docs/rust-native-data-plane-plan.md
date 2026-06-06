# igniter-ledger Rust Native Data Plane Plan

Status date: 2026-05-02
Status: Package Agent planning note, not a stable public API promise
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Purpose

Define what should move from Ruby to Rust in `igniter-ledger`, and what should
stay Ruby-owned. The goal is not a full rewrite. The target shape is a Ruby
control plane over a Rust data plane.

This plan intentionally keeps the package name `igniter-ledger` for now. The
possible brand move from Store to Ledger is a separate Architect Supervisor
slice after the current Package Agent work settles.

## Baseline

Current native extension already exists under `ext/igniter_store_native` and
provides native versions of:

- `Fact`
- `FactLog`
- `FileBackend`

Known native gaps:

- `Fact#producer` is accepted by Ruby wrappers but not yet persisted in native
  `FactData`.
- Segmented storage is still Ruby-owned.
- Codec implementations are still Ruby-owned.
- Compact delta durability semantics are still being hardened.
- Push/subscription delivery is Ruby-owned and synchronous.

## Architecture Rule

```text
Ruby control plane
  protocol, descriptors, manifests, MCP, HTTP, policy, app integration

Rust data plane
  facts, segments, codecs, indexes, durability, replay, hot change delivery
```

Ruby should remain the place where package semantics are inspectable and easy to
iterate. Rust should own the hot paths where correctness and throughput matter:
binary formats, checksums, segment scans, durable flush policies, indexing, and
high-volume change delivery.

## Priority 0: Native Parity Baseline

Goal: make the current native extension boringly equivalent to the Ruby path
before moving more surface area.

Tasks:

- Persist and round-trip `Fact#producer` in native `FactData`.
- Add native conformance specs that compare Ruby and native `Fact#to_h`,
  `FactLog#facts_for`, `#latest_for`, `#query_scope`, and replay ordering.
- Keep native fallback behavior explicit: when the extension is unavailable,
  pure Ruby remains the reference implementation.
- Document native gaps in one status section so pending specs do not become
  tribal memory.

Acceptance:

- Pending native producer specs can be made active or clearly re-scoped.
- Ruby/native fact hashes match for all supported fields.
- Native mode does not silently drop any field accepted by public Ruby wrappers.

## Priority 1: Segmented Storage Core

Goal: move segment lifecycle and segment metadata into Rust.

Rust should eventually own:

- per-store/per-bucket directory layout
- active segment state
- segment rotation
- manifest writes
- quarantine receipts
- replay over segment ranges
- storage stats and segment manifests
- retention purge receipt scanning where practical

Ruby should keep:

- constructor-level package API
- policy names and option validation
- Open Protocol integration
- docs and conformance wrappers

Acceptance:

- Ruby and Rust segmented backends expose the same package-facing methods:
  `write_fact`, `replay`, `close`, `checkpoint!`, `storage_stats`,
  `segment_manifest`, `durability_snapshot`.
- Crash/reopen behavior matches the Storage Durability Contract.
- `storage_stats` avoids repeated expensive full directory scans where a manifest
  index can answer the same question.

## Priority 2: Codecs

Goal: move storage format work to Rust while preserving Ruby-level codec names.

Rust candidates:

- `json_crc32`
- `compact_delta_zlib`
- future compact binary formats
- future encrypted segment envelope
- checksum/integrity validation

Important constraint:

```text
codec name is API-level metadata
codec implementation is replaceable
```

The Ruby package should still be able to say `codec: :compact_delta_zlib`. The
implementation may be Ruby or Rust behind that name.

Acceptance:

- Codec output has stable manifest metadata: codec name, schema version,
  compression, checksum/integrity mode.
- Codec crash behavior is covered by durability specs.
- Benchmarks compare Ruby and Rust implementations with speed and bytes/fact.

## Priority 3: Durable Flush, Checkpoint, Compaction

Goal: make durability explicit and efficient.

Rust should own:

- flush policy execution
- fsync policy when introduced
- atomic manifest writes
- compacted segment creation
- segment seal/checkpoint routines
- corruption/truncation detection

The package should distinguish:

```text
accepted -> buffered -> flushed -> checkpointed -> compacted
```

Acceptance:

- Receipts or snapshots can report the durability state honestly.
- A successful write is never implied to be crash-durable unless it has reached
  the configured durability boundary.
- Benchmarks include throughput cost for each durability policy.

## Priority 4: Read And Replay Indexes

Goal: make high-volume reads fast without turning the protocol into a database.

Rust candidates:

- per-store key index
- per-history partition index
- time-bucket replay index
- latest-per-key index
- segment min/max timestamp index
- manifest-backed storage stats

Non-goal:

- Do not add a general query planner in this slice.
- Do not expose SQL-like semantics.

Acceptance:

- Replay for `store`, `since`, `as_of`, and partition-like access avoids full
  scans when segment metadata can prune the search.
- Existing Ruby query semantics remain the compatibility target.

## Priority 5: Changefeed Data Plane

Goal: prepare Rust to host the hot event buffer once the Changefeed model is
specified.

Rust may own:

- bounded async queue
- cursor assignment
- per-subscriber fan-out buffers
- backpressure/drop policy
- durable cursor checkpoints

Ruby should keep:

- subscription descriptors
- policy naming
- adapter bindings
- MCP/HTTP/TCP/SSE/WebSocket surfaces

Acceptance:

- Changefeed events are derived from committed facts, not a second source of
  truth.
- The Rust queue can be disabled or replaced without changing Open Protocol
  semantics.

## Package Agent Guidance

Recommended sequence after the current durability slice:

1. Native parity baseline.
2. Rust segmented storage spike behind the current Ruby API.
3. Rust codec benchmark parity.
4. Rust durability/checkpoint implementation.
5. Changefeed data-plane spike only after the Changefeed spec is accepted.

Handoff should report:

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/rust-native-data-plane
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
