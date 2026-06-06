# Igniter Ledger Segmented Storage Hardening Proposal

Status date: 2026-05-02.
Status: proposal for the next `SegmentedFileBackend` hardening slice.
Not a stable public API.

## Claim

`SegmentedFileBackend` is now a valid proof for high-volume store files:
per-store partitions, time buckets, segment manifests, codec selection, and
retention receipts are in place.

The next slice should not add a bigger storage abstraction yet. It should make
the current segmented storage substrate harder to lose data with, easier to
inspect, and ready to expose through Ledger Open Protocol and MCP.

```text
IgniterStore
  -> SegmentedFileBackend
     -> segment lifecycle hardening
     -> codec correctness hardening
     -> manifest/readiness metadata
     -> retention receipt semantics
        |
        v
Ledger Open Protocol metadata
        |
        v
MCP read-only tools
```

## Current State

Shipped:

- `Igniter::Store.segmented(root_dir, **opts)` factory.
- `SegmentedFileBackend` with `write_fact`, `replay`, `checkpoint!`, `close`.
- Per-store and per-time-bucket WAL layout:
  `wal/store=<name>/date=<bucket>/segment-000001.wal`.
- Manifest sidecars written on seal:
  `segment-000001.wal.manifest.json`.
- Codec layer:
  - `json_crc32`
  - `compact_delta_zlib`
- Per-store codec map.
- Retention policies:
  - `permanent`
  - `rolling_window`
  - `ephemeral`
- Physical purge receipts:
  `segment-000001.wal.purged.json`.

Verified:

```text
packages/igniter-ledger:
  391 examples, 0 failures, 2 pending

segmented_file_backend_spec:
  41 examples, 0 failures
```

## Why Hardening Comes Next

The current proof is strong enough to keep building on. It is also now close
enough to real storage that the next mistakes would be expensive:

- crash recovery must not silently lose live segment data
- compact codecs must preserve boolean and nil payloads
- physical purge must remain auditable
- manifests must become the read model for agents and MCP
- Ledger Open Protocol should expose storage state without leaking file paths as
  the primary API

This is especially important for cluster sensor streams where data volume makes
manual inspection impossible.

## Boundary: Logical Compaction vs Physical Purge

There are now two retention planes and they must stay distinct.

```text
Logical compaction
  IgniterStore#compact
  -> rebuilds visible fact history according to policy
  -> writes receipt facts to :__compaction_receipts

Physical purge
  SegmentedFileBackend#purge!
  -> deletes sealed storage segments according to policy
  -> writes .purged.json filesystem receipts
```

Rules:

- Logical compaction changes the visible fact log.
- Physical purge changes stored segment availability.
- Both must emit receipts before deleting/rebuilding.
- Neither should silently erase history.
- A future protocol view should report both planes separately.

## Hardening Targets

### 1. Crash Recovery For Non-Resumable Codecs

Current pressure:

`compact_delta_zlib` is intentionally not resumable after crash. A live compact
segment must be sealed or recovered with the correct codec metadata.

Target:

- orphaned live segments should record the actual codec, not default to
  `json_crc32`
- recovery should not produce a sealed segment that replays as empty because the
  wrong codec was recorded
- if a segment cannot be safely recovered, write an explicit quarantine receipt
  instead of silently accepting data loss

Acceptance:

- test: compact segment with unclean shutdown replays pre-crash facts or emits a
  quarantine receipt
- test: orphan manifest records `compact_delta_zlib`
- test: replay does not silently return `[]` for a valid compact orphan

### 2. Codec Value Correctness

Current pressure:

Compact codecs are optimized for homogeneous sensor/history payloads, but they
must preserve Ruby value semantics.

Target:

- preserve `false`
- preserve `nil` when the field exists
- distinguish absent fields from present `nil` where the codec shape supports it
- keep symbol/string coercion rules explicit

Acceptance:

- test: compact codec round-trips `false`
- test: compact codec round-trips present `nil`
- test: mixed symbol/string keys preserve expected values

### 3. Manifest As Storage Read Model

Current pressure:

Manifests already exist, but agents should not scrape arbitrary files to
understand storage state.

Target metadata:

```ruby
{
  schema_version: 1,
  stores: {
    "sensor_readings" => {
      segment_count: 12,
      sealed_count: 11,
      live_count: 1,
      codecs: ["compact_delta_zlib"],
      byte_size: 123_456,
      fact_count: 100_000,
      min_timestamp: 1_746_182_400.0,
      max_timestamp: 1_746_183_000.0
    }
  }
}
```

Acceptance:

- `SegmentedFileBackend#segment_manifest(store: nil)` returns structured
  manifest data
- `SegmentedFileBackend#storage_stats(store: nil)` returns compact stats
- no caller needs to know the directory layout for normal inspection
- metadata includes purged/quarantined receipt counts when present

### 4. Protocol And MCP Readiness

Current pressure:

MCP should inspect storage via protocol metadata, not via direct filesystem
access.

Target protocol shape:

```text
op: :storage_stats
op: :segment_manifest
```

or, if keeping the protocol waist smaller:

```text
op: :metadata_snapshot
  result.storage = { ... }
```

Acceptance:

- storage metadata is available through `Protocol::Interpreter`
- remote mode can fetch the same data through `/v1/dispatch`
- MCP proposal can lower `storage_stats` and `segment_manifest` tools to Open
  Protocol operations or named metadata views
- no MCP tool reads segment files directly

### 5. Retention Receipt Semantics

Current pressure:

Physical purge receipts exist as `.purged.json` files. The next step is making
their meaning stable enough for sync and diagnostics.

Target:

- receipt includes segment id, codec, byte size, fact count, min/max timestamp,
  policy, purge time, and reason
- receipt path is not the only identifier
- purged receipt listing is bounded/filterable
- receipts can be summarized in storage metadata

Acceptance:

- test: purge receipt includes stable `segment_id`
- test: `purge_receipts(store:)` is sorted and filterable
- test: storage stats report purge receipt count

## Non-Goals

- No encryption implementation in this slice.
- No columnar format in this slice.
- No native/Rust rewrite in this slice.
- No public storage API stability promise.
- No MCP implementation unless protocol metadata is ready enough.

## Suggested Implementation Order

1. Fix compact codec value lookup and add boolean/nil round-trip specs.
2. Fix orphan sealing to preserve codec identity or quarantine explicitly.
3. Add structured `segment_manifest` and `storage_stats` backend methods.
4. Add protocol metadata exposure.
5. Update MCP proposal/tool list if operation names change.
6. Add one conformance smoke:
   local backend metadata equals protocol metadata equals remote dispatch
   metadata.

## First Slice Acceptance

```text
1. compact_delta_zlib preserves false and present nil values
2. compact_delta_zlib crash/orphan behavior is explicit and tested
3. storage_stats and segment_manifest are available on SegmentedFileBackend
4. Protocol::Interpreter exposes storage metadata without file scraping
5. MCP can consume storage metadata through Open Protocol
6. igniter-ledger package specs remain green
```

## Handoff

```text
[Architect Supervisor / Codex]
Track: igniter-ledger-segmented-storage-hardening
Status: proposal, next slice after segmented WAL + retention.
[D] Keep SegmentedFileBackend; harden it before adding a bigger abstraction.
[D] Distinguish logical compaction from physical purge.
[D] Storage inspection should flow through manifests -> protocol metadata -> MCP.
[R] No silent replay loss for orphaned compact segments.
[R] Compact codecs must preserve false/nil semantics.
[R] Physical purge must remain receipt-first and auditable.
Next: implement hardening targets 1-3, then expose storage metadata through protocol.
```
