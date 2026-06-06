# Igniter Ledger Storage Metadata Conformance Proposal

Status date: 2026-05-02.
Status: proposal for the next slice after segmented storage hardening.
Not a stable public API.

## Claim

`SegmentedFileBackend` now exposes storage state through structured metadata:
`storage_stats`, `segment_manifest`, protocol operations, and
`metadata_snapshot.storage`.

The next slice should prove that this metadata is the same logical truth across
all access paths:

```text
SegmentedFileBackend
  -> IgniterStore
  -> Protocol::Interpreter
  -> WireEnvelope
  -> LedgerServer /v1/dispatch
  -> MCP read-only tools
```

This is the bridge from "storage exists" to "agents and operators can rely on
storage metadata without scraping files."

## Current State

Shipped:

- `SegmentedFileBackend#storage_stats(store: nil)`.
- `SegmentedFileBackend#segment_manifest(store: nil)`.
- `IgniterStore#storage_stats` and `IgniterStore#segment_manifest`.
- `Protocol::Interpreter#storage_stats` and
  `Protocol::Interpreter#segment_manifest`.
- `WireEnvelope` ops:
  - `op: :storage_stats`
  - `op: :segment_manifest`
- `metadata_snapshot` includes `storage` when backend supports it.
- Purge and quarantine receipt counts are included in storage stats.

Verified:

```text
packages/igniter-ledger:
  428 examples, 0 failures, 2 pending

targeted storage/protocol specs:
  104 examples, 0 failures
```

## Why This Slice Matters

Storage metadata is now a capability surface, not just an implementation detail.

For cluster sensor streams and agent-operated stores, we need stable answers to
questions like:

- How large is this store?
- Which codecs are active?
- Are there live segments?
- Are there quarantined segments?
- Did retention purge anything?
- Can a remote agent see the same storage state as the local process?

If these answers differ between local backend calls, protocol calls, server
dispatch, and MCP tools, operators will not be able to trust the store.

## Conformance Planes

### 1. Backend Plane

Direct storage view:

```ruby
backend.storage_stats(store: :sensor_readings)
backend.segment_manifest(store: :sensor_readings)
```

This is the source view for physical storage metadata.

### 2. Store Plane

Application-facing storage view:

```ruby
store.storage_stats(store: :sensor_readings)
store.segment_manifest(store: :sensor_readings)
```

This proves that `IgniterStore` can expose backend capabilities without making
the application know the backend class.

### 3. Protocol Plane

Protocol-facing storage view:

```ruby
store.protocol.storage_stats(store: :sensor_readings)
store.protocol.segment_manifest(store: :sensor_readings)
store.protocol.metadata_snapshot[:storage]
```

This is the semantic waist for non-Ruby clients and agents.

### 4. Wire/Server Plane

Remote storage view:

```text
POST /v1/dispatch
  { op: :storage_stats, packet: { store: "sensor_readings" } }

POST /v1/dispatch
  { op: :segment_manifest, packet: { store: "sensor_readings" } }
```

This proves remote operators and future MCP adapters do not need filesystem
access.

### 5. MCP Plane

Agent-facing storage view:

```text
tool: storage_stats
  -> op: :storage_stats

tool: segment_manifest
  -> op: :segment_manifest

resource: igniter-ledger://segments
  -> op: :segment_manifest or metadata_snapshot.storage
```

This should remain read-only in the first MCP slice.

## Conformance Rules

- Backend, store, protocol, and wire views must agree on store names.
- `storage_stats` must not include per-segment arrays.
- `segment_manifest` must include per-segment arrays.
- Store filters must behave the same across all planes.
- In-memory stores should return `nil` for storage-specific metadata.
- Segmented stores should include `metadata_snapshot.storage`.
- No conformance path should require direct file reads outside the backend.
- Wire responses must stay envelope-shaped and preserve `request_id`.

## Metadata Shape

`storage_stats` should stay compact:

```ruby
{
  "schema_version" => 1,
  "generated_at" => 1_746_182_400.0,
  "stores" => {
    "sensor_readings" => {
      "segment_count" => 12,
      "sealed_count" => 11,
      "live_count" => 1,
      "codecs" => ["compact_delta_zlib"],
      "byte_size" => 123_456,
      "fact_count" => 100_000,
      "min_timestamp" => 1_746_182_400.0,
      "max_timestamp" => 1_746_183_000.0,
      "purge_receipt_count" => 2,
      "quarantine_receipt_count" => 0
    }
  }
}
```

`segment_manifest` may include the same aggregate fields plus:

```ruby
{
  "segments" => [
    {
      "segment_id" => "sensor_readings/2026-05-02/000001",
      "codec" => "compact_delta_zlib",
      "fact_count" => 64,
      "byte_size" => 4096,
      "min_timestamp" => 1_746_182_400.0,
      "max_timestamp" => 1_746_182_405.0,
      "sealed" => true,
      "sealed_at" => 1_746_182_406.0
    }
  ]
}
```

## First Slice Acceptance

Recommended first slice: conformance smoke across local, protocol, and wire.

Acceptance:

- Build one segmented store with two stores and mixed live/sealed segments.
- Backend `storage_stats` equals store `storage_stats` after removing
  volatile `generated_at`.
- Store `storage_stats` equals protocol `storage_stats` after removing
  volatile `generated_at`.
- Wire `op: :storage_stats` returns the same logical payload.
- Wire `op: :segment_manifest` returns `segments`.
- Store filter returns exactly one store at every layer.
- `metadata_snapshot` includes `storage` for segmented backend and omits it for
  in-memory backend.
- Existing package specs remain green.

Suggested smoke:

```text
1. open Igniter::Store.segmented(tmpdir, codec: { sensor_readings: :compact_delta })
2. write sensor_readings facts and agent_signals facts
3. checkpoint to create sealed + live segments
4. compare backend/store/protocol/wire storage_stats
5. compare protocol/wire segment_manifest
6. verify metadata_snapshot.storage exists
7. verify in-memory metadata_snapshot has no storage key
```

## MCP Readiness Criteria

MCP read-only implementation may start when:

- `storage_stats` and `segment_manifest` conformance smoke is green.
- Tool outputs can preserve `schema_version`, `request_id`, `status`, and
  `source_protocol_op`.
- Query/replay limits are enforced or explicitly required by tool input schema.
- Mutating tools remain disabled.
- MCP tools call `Protocol::Interpreter#dispatch` or remote `/v1/dispatch`, not
  backend methods directly.

## Non-Goals

- No MCP implementation in this proposal unless conformance is already green.
- No write tools.
- No encryption.
- No new codec.
- No public API stability promise.

## Follow-Up Horizon

After this conformance slice:

1. Implement read-only MCP adapter with `metadata_snapshot`, `storage_stats`,
   `segment_manifest`, `query`, `resolve`, `sync_profile`.
2. Add bounded replay semantics before exposing replay as an MCP tool.
3. Add a storage readiness report for cluster sensor stores.
4. Revisit durability contract for `compact_delta_zlib` unflushed batches.

## Handoff

```text
[Architect Supervisor / Codex]
Track: igniter-ledger-storage-metadata-conformance
Status: proposal, next slice after storage metadata API shipped.
[D] Storage metadata is now a protocol-facing capability surface.
[D] Conformance must prove backend/store/protocol/wire views agree.
[D] MCP should consume storage metadata through Open Protocol, not file access.
[R] storage_stats remains aggregate; segment_manifest carries per-segment detail.
[R] In-memory backend returns nil storage metadata.
[R] Segmented backend includes metadata_snapshot.storage.
Next: implement conformance smoke, then begin read-only MCP adapter.
```
