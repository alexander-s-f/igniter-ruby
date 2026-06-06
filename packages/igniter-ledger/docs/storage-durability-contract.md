# Storage Durability Contract

**Package:** igniter-ledger
**Status:** active
**Date:** 2026-05-02

## What this document covers

This document states exactly what survives a process crash for each codec and
flush policy combination. "Crash" means the Ruby process is killed without
calling `close` or `checkpoint!` on the backend.

---

## Codec summary

| Codec | Format | Durability mode | Loss window |
|---|---|---|---|
| `json_crc32` | One CRC32-framed JSON record per fact | Immediate (sync write per fact) | Zero — every accepted fact is on disk |
| `compact_delta_zlib` | Compressed batch frames (MessagePack + Zlib) | Batched (default BATCH_SIZE=64) | Up to 63 facts — anything buffered since the last batch write |

---

## json_crc32

Every fact is encoded as a single CRC32-framed JSON record and written
immediately to the OS via a file opened with `sync: true`.  No in-memory
buffering.  **Every accepted fact is durable as soon as `write_fact` returns.**

**Crash behaviour:** all facts survive.

**Size tradeoff:** approximately 380 bytes/fact for a GPS-like schema.  Suitable
for low-to-medium write rates and for stores where durability matters more than
storage efficiency.

---

## compact_delta_zlib

Facts are compressed together as batches of up to `BATCH_SIZE` (64) entries.
Each batch is a Zlib-compressed MessagePack frame.  The first fact in a segment
causes a header frame to be written immediately (store name, field list, term).
Subsequent facts accumulate in an in-memory buffer (`@batch_buf`) until the
buffer reaches `BATCH_SIZE`, at which point the batch is written to disk.

**Default behaviour (`:batch` policy):** if the process is killed with N facts
in the buffer (N < 64), those N facts are lost.  The header frame is already on
disk, so the segment is valid but empty when recovered.

**Size tradeoff:** approximately 23 bytes/fact for a GPS-like schema (16× smaller
than json_crc32).  Suitable for high-frequency sensor streams where a bounded
loss window is acceptable.

---

## Flush policies

The `flush:` parameter on `SegmentedFileBackend.new` controls how aggressively
sub-batch data is pushed to disk.

### `:batch` (default)

No extra flushing.  Facts accumulate in `@batch_buf` until `BATCH_SIZE` (64) is
reached, or until `close`/`checkpoint!` is called.

- **Loss window:** up to 63 facts per store.
- **Throughput:** highest (one IO per 64 facts).
- **Use when:** you can tolerate losing up to one batch on crash, and throughput
  matters (sensor streams, GPS tracks, telemetry).

### `:on_write`

After every `write_fact`, any remaining buffered facts are flushed to disk.
Each fact becomes its own small batch frame.

- **Loss window:** zero.
- **Throughput:** lowest (one IO per fact, same as json_crc32 but with
  compact encoding overhead).
- **Use when:** durability is non-negotiable and you still want compact
  on-disk format.

### `{ every_n: N }`

Flush after every N facts per store.  Resets the counter after each flush.

- **Loss window:** up to N−1 facts.
- **Throughput:** one IO per N facts (tunable tradeoff).
- **Use when:** you want a predictable, configurable loss window without the
  overhead of per-fact IO.

```ruby
# Example: flush every 10 facts
backend = SegmentedFileBackend.new(root, codec: :compact_delta, flush: { every_n: 10 })
```

---

## Recovery on startup

When a new `SegmentedFileBackend` is opened, `recover_orphaned_segments!` runs
automatically.  It finds any segment files without a manifest (i.e., segments
that were live when the previous process crashed) and seals them:

1. The file is opened in append mode and closed (forces OS buffer flush).
2. The fact count is read from the file's on-disk frames (not from memory).
3. A manifest is written with the recovered fact count.

For `json_crc32`: all on-disk frames are counted → 0 facts lost.
For `compact_delta` (`:batch`): only complete batch frames are counted → buffered
sub-batch facts that were never written to disk are not in the manifest.  Their
count is honestly reported as zero, not silently backfilled.

---

## durability_snapshot

`SegmentedFileBackend#durability_snapshot` returns the current durability
posture at runtime — useful for health checks and alerting:

```ruby
snap = backend.durability_snapshot
# {
#   "policy" => "batch",         # or "on_write", "every_n:10"
#   "stores" => {
#     "readings" => {
#       "codec"          => "compact_delta_zlib",
#       "buffered_count" => 12,    # facts in memory, not yet on disk
#       "facts_on_disk"  => 64,    # facts confirmed written
#       "durability"     => "buffered"   # or "flushed"
#     }
#   }
# }
```

A store with `durability: "buffered"` has facts that will be lost if the
process is killed.  A store with `durability: "flushed"` has all accepted facts
on disk.

---

## Tradeoff matrix

| Policy | Loss window | IO amplification | Recommended for |
|---|---|---|---|
| `:batch` (json_crc32) | 0 | 1× per fact | All stores, moderate rate |
| `:batch` (compact_delta) | ≤ 63 facts | 1× per 64 facts | High-rate sensor/telemetry |
| `:on_write` (compact_delta) | 0 | 1× per fact | High-rate + durable |
| `every_n: N` (compact_delta) | ≤ N−1 facts | 1× per N facts | Configurable tradeoff |

---

## What is NOT covered

- Power failure durability (`fsync` to physical media). The current implementation
  flushes to the OS kernel buffer but does not call `fsync`. A host power failure
  before the OS flushes its page cache can still lose data regardless of policy.
- Encryption at rest.
- Replication or multi-node durability.

These are non-goals for the current package version.

---

## Benchmark plan integration

The `docs/storage-format-benchmark-plan.md` should include a durability policy
dimension when comparing formats and write rates.  Each benchmark run should
record the policy used so that throughput numbers are never compared across
different durability levels without explicit annotation.
