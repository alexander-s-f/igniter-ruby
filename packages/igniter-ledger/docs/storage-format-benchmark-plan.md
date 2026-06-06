# Igniter Ledger Storage Format Benchmark Plan

Status date: 2026-05-02.
Status: proposal for compact storage, partitioning, encryption, and benchmark
work. Not a stable public API.

## Motivation

Cluster sensor streams change the pressure on `igniter-ledger`.

The current file backend is intentionally simple:

```text
store.wal
  append-only CRC32-framed JSON Fact packets

store.wal.snap
  optional snapshot sidecar for faster replay
```

This is excellent for correctness and debuggability, but sensor streams need a
more explicit storage plan:

- high write throughput
- compact disk footprint
- bounded file sizes
- partition lifecycle
- optional encryption at rest
- predictable replay and sync performance

## Current Baseline

Current WAL frame:

```text
[4 bytes body_len][JSON Fact body][4 bytes CRC32(body)]
```

Current fact body:

```ruby
{
  id: "...",
  store: :sensor_readings,
  key: "...",
  value: { sensor_id: "s1", value: 42.0, recorded_at: 123.4 },
  value_hash: "...sha256...",
  causation: nil,
  timestamp: 123.4,
  term: 0,
  schema_version: 1,
  producer: { ... }
}
```

Current strengths:

- append-only and crash-tolerant
- frame CRC detects truncated/corrupt tail
- immutable facts preserve audit and time travel
- snapshot sidecar reduces startup replay cost
- format is easy to inspect

Current limits:

- JSON is verbose
- every fact repeats store/key/field names
- one WAL can grow without partition bounds
- CRC32 is integrity hint, not cryptographic authentication
- no encryption layer
- no benchmark data for sensor stream profiles

## Target Shape

Separate file mechanics from body encoding:

```text
SegmentWriter
  -> FrameCodec
      -> Serializer
      -> Compressor
      -> Encryptor
  -> partitioned WAL segments
```

`FileBackend` should eventually own segment append/replay. A codec should own
how one fact packet becomes bytes.

## Candidate Formats

Benchmark these formats first:

| Codec | Shape | Why |
|-------|-------|-----|
| `json_crc32` | current JSON + CRC32 | baseline |
| `msgpack_crc32` | MessagePack + CRC32 | compact structured baseline |
| `json_zstd_crc32` | JSON -> Zstd + CRC32 | easy migration, good compression |
| `msgpack_zstd_crc32` | MessagePack -> Zstd + CRC32 | likely best size/speed balance |
| `msgpack_lz4_crc32` | MessagePack -> LZ4 + CRC32 | speed-oriented compression |
| `msgpack_zstd_aead` | MessagePack -> Zstd -> AEAD | encrypted compact candidate |

Later candidates:

- dictionary-coded sensor batches
- columnar segment snapshots
- per-store binary schemas
- delta encoding for timestamp/store/key repetition

Do not start with columnar storage. First prove frame codecs and segment
partitioning.

## Encryption Direction

Encryption should wrap serialized/compressed body bytes, not the whole file.

Preferred order:

```text
canonical fact hash on plaintext value
serialize fact packet
compress bytes
encrypt bytes with AEAD
write encrypted frame
```

Target AEAD candidates:

- XChaCha20-Poly1305
- AES-256-GCM

Encrypted frame metadata needs:

```ruby
{
  codec: :msgpack_zstd_aead,
  key_id: "local-dev-1",
  nonce: "...",
  auth_tag: "...",
  body_len: ...
}
```

Rules:

- `value_hash` remains a hash of canonical plaintext value.
- AEAD auth tag becomes the real integrity check.
- CRC32 can remain as a fast corruption hint for unencrypted codecs.
- Keys are not stored in WAL segments.
- Key rotation must be segment-level or chunk-level, not file-global.

## Partitioning And Segments

A single WAL file must not grow into terabytes. Use partitioned segments.

Proposed directory layout:

```text
store-data/
  manifest.json
  wal/
    store=sensor_readings/
      date=2026-05-02/
        segment-000001.wal
        segment-000002.wal
      date=2026-05-03/
        segment-000001.wal
    store=agent_signals/
      date=2026-05-02/
        segment-000001.wal
  snapshots/
    store=sensor_readings/
      snapshot-2026-05-02T10-00-00.snap
  receipts/
    compaction/
```

Partition dimensions:

- store name
- time bucket, usually hour or day
- segment number
- optional cluster id for multi-cluster ingest

Segment rotation triggers:

- max segment bytes, e.g. 64 MB / 256 MB / 1 GB
- max fact count
- time bucket rollover
- explicit checkpoint
- encryption key rotation

Segment manifest:

```ruby
{
  schema_version: 1,
  segment_id: "sensor_readings/2026-05-02/000001",
  store: :sensor_readings,
  codec: :msgpack_zstd_aead,
  key_id: "cluster-key-2026-05",
  fact_count: 1_000_000,
  byte_size: 123_456_789,
  min_timestamp: 123.0,
  max_timestamp: 456.0,
  min_key: nil,
  max_key: nil,
  sealed: true,
  checksum: "..."
}
```

Replay should use manifests to skip irrelevant segments for:

- store filter
- time range
- sync cursor
- retention cleanup

## Retention And Compaction

Sensor data should usually use tiered retention:

```text
hot local store:
  high-resolution facts for minutes/hours

warm local/server store:
  compressed segments for hours/days

cold sync hub:
  downsampled or compacted facts for days/months
```

Compaction strategies to benchmark:

- keep all raw facts
- latest per key
- rolling window
- downsample by time bucket
- aggregate rollup facts, e.g. min/max/avg/count per sensor per minute
- retain raw facts until sync hub ACK, then compact

Important boundary:

Compaction must emit receipts. It should never silently erase history.

## Sensor Stream Benchmark Profiles

Benchmark against realistic profiles:

### Profile A: Small Lab

```text
sensors: 100
rate: 1 event/sec each
payload: 3-6 numeric fields
duration: 10 minutes
```

### Profile B: Cluster Telemetry

```text
sensors: 10_000
rate: 1 event/sec each
payload: node_id, sensor_id, metric, value, recorded_at
duration: 10 minutes
```

### Profile C: Burst

```text
sensors: 1_000
rate: 100 events/sec each for 30 seconds
payload: compact numeric readings
```

### Profile D: Mixed Store

```text
sensor_readings high-volume history
agent_signals medium-volume history
calibration low-volume persistent records
relations/projections enabled
```

## Metrics

Collect:

- ingest throughput: facts/sec
- p50/p95/p99 write latency
- bytes/fact on disk
- total segment size
- compression ratio against JSON baseline
- CPU time per 1M facts
- memory during ingest
- replay throughput: facts/sec
- filtered replay throughput by store/time
- startup time from full WAL
- startup time from snapshot + WAL delta
- compaction time
- sync profile generation time
- encrypted write/read overhead

## Benchmark Harness

Suggested command shape:

```text
bundle exec ruby packages/igniter-ledger/bench/storage_formats.rb \
  --profile cluster_telemetry \
  --codec msgpack_zstd \
  --segment-by store,date \
  --segment-size 256mb \
  --duration 600
```

Output:

```json
{
  "profile": "cluster_telemetry",
  "codec": "msgpack_zstd",
  "facts": 6000000,
  "facts_per_sec": 185000,
  "bytes_per_fact": 42,
  "total_bytes": 252000000,
  "write_p95_ms": 1.2,
  "replay_facts_per_sec": 310000,
  "startup_ms": 4200
}
```

Keep benchmark output machine-readable so agents can compare runs.

## Implementation Order

1. Add benchmark harness using current `json_crc32` codec.
2. Add segmented WAL writer/reader without changing body codec.
3. Add MessagePack codec.
4. Add Zstd/LZ4 compression codecs.
5. Add AEAD encrypted codec.
6. Add manifest-driven replay filtering.
7. Add retention/compaction benchmark cases.
8. Add sync profile benchmark cases.

## Acceptance For First Slice

- Current JSON WAL benchmark exists.
- Benchmark can generate at least Profile A and Profile B.
- Results include facts/sec, bytes/fact, replay speed, and total size.
- No production storage behavior changes yet.
- Output is committed as ignored/generated benchmark artifacts or printed JSON.

## Handoff

```text
[Architect Supervisor / Codex]
Track: igniter-ledger-storage-format
Status: benchmark and storage-format proposal drafted.
[D] Sensor streams require compact codecs, partitioned WAL segments, and
benchmark evidence before changing storage format.
[R] Preserve append-only facts, causation, time travel, and receipts.
[R] Start with benchmarks and segment manifests before encryption or columnar
storage.
[R] Encryption should wrap compressed frame bodies with AEAD; keys stay outside
segments.
[S] Current baseline is CRC32-framed JSON WAL plus optional .snap snapshot.
Next: implement benchmark harness for json_crc32 baseline and sensor profiles.
```
