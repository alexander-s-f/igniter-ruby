# Native TBackend Gap Review

Date: 2026-05-07
Source: external agent review relayed by user
Status: review-signal
Owner: `[Architect Supervisor / Codex]`

## Purpose

Capture a high-value external review of the current `igniter-ledger` native data
plane and its relationship to Igniter-Lang `TBackend` expectations.

This document is not a track and does not authorize implementation. It records
pressure that should be routed into future Package Agent / Bridge Agent slices.

## Positive Assessment

The review validates several major architecture choices:

- `SegmentedFileBackend` is assessed as a real WAL-style storage engine, not a
  thin proof of concept.
- The Rust native data plane is placed in the right layer: hot in-memory fact
  indexes and hash-heavy operations.
- MCP over `Protocol::Interpreter` is called out as a strong
  human-agent-facing protocol surface.
- `TBackendAdapterDescriptor` is judged directionally correct: descriptor-first,
  diagnostics-capable, and suitable for capability negotiation before runtime
  execution.

## Main Gaps

### G1. BiHistory Is Declared But Not Physically Served

The descriptor can expose `bihistory_read` and `transaction_time`, but the native
data plane does not yet implement a true two-axis query:

```text
at(vt:, tt:)
```

The current native latest/as-of shape is effectively transaction-time oriented.
That is not sufficient for honest `BiHistory[T]`.

### G2. `valid_time` Is A Field, Not An Indexed Query Axis

Facts carry valid-time-like data, but the native `FactLog` does not have a
valid-time index. History range access therefore risks degrading into scans.

Recommended future shape:

```text
by_valid_time: BTreeMap<OrderedF64, Vec<usize>>
range_by_valid_time(store, key?, from, to)
```

### G3. Ruby And Rust FactLog Surfaces Are Split

Native mode still relies on Ruby-side tracking for some whole-log operations,
such as `all_facts` through seen stores. That is fragile and can become slow.

Recommended future shape:

```text
FactLog#all_facts implemented directly in Rust
```

### G4. Native `from_h` / Replay Fidelity Gap

Known network replay gap: rebuilding facts in native mode can recompute `id` and
`transaction_time`. That breaks causation and time-travel fidelity across wire
or replay boundaries.

Recommended future shape:

```text
Fact.restore(id:, transaction_time:, ...)
```

or equivalent native restore constructor that preserves identity and time.

### G5. Descriptor Does Not Yet Drive RuntimeMachine

`TBackendAdapterDescriptor` is useful evidence, but the RuntimeMachine does not
consume it for live routing yet. This is intentionally deferred in current
Igniter-Lang status and should remain behind explicit Architect approval.

## Suggested Priority Order

1. Add native valid-time range index/query.
2. Add native bitemporal `at(vt:, tt:)` query.
3. Add native fact restore path preserving `id` and `transaction_time`.
4. Add native `all_facts`.
5. Only after descriptor evidence is stable, plan RuntimeMachine compatibility
   consumption and routing.

## Architect Notes

[D] Treat this review as aligned with the current descriptor-first strategy.

[D] Do not claim `BiHistory[T]` production support from descriptor capability
alone. Descriptor support and physical serving are separate states.

[R] The next useful large Package Agent slice is likely:

```text
native-valid-time-and-replay-fidelity-v0
```

with acceptance focused on indexes, query semantics, and replay identity
preservation before any RuntimeMachine binding.
