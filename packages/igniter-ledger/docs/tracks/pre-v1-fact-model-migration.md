# Track: Pre-v1 Fact Model Migration

Status date: 2026-05-03
Status: landed; supervisor cleanup applied
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Perform the P0 breaking Fact model migration before v1:

```text
timestamp -> transaction_time
term      -> valid_time
producer  persisted in native mode
derivation added to Fact
```

This is the next large vertical slice. Do not implement key schema, reactive
derivation descriptors, or bi-temporal query APIs yet.

## Context

The accepted pre-v1 direction is documented in:

- `docs/pre-v1-core-model-proposal.md`
- `docs/intelligent-ledger/availability-snapshot-proof.md`
- `docs/rust-native-data-plane-plan.md`

The availability proof showed that derived facts need inline explanation, not
only separate receipt facts. Native mode now stores `producer`; `term` remains a
compatibility alias while `valid_time` is the canonical domain-time field.

## Scope

Update Ruby, native Rust, wire/hash serialization, and specs so the canonical
Fact fields are:

```ruby
id
store
key
value
value_hash
causation
transaction_time
valid_time
schema_version
producer
derivation
```

Compatibility aliases are required during transition:

```ruby
fact.timestamp # alias for transaction_time
fact.term      # alias for valid_time, or 0/nil-compatible wrapper if needed
```

## Required Semantics

### transaction_time

- Store-owned wall-clock epoch Float.
- Replaces `timestamp` as the canonical field.
- Must remain comparable across process restarts.
- Do not use process monotonic time for persisted facts.

### valid_time

- Writer-supplied nullable Float.
- Replaces `term`.
- If nil, read/query behavior may treat it as `transaction_time` later.
- This track only stores and round-trips it; full `valid_as_of` APIs are later.

### producer

- Optional Hash.
- Must round-trip in Ruby mode and native mode.
- Existing producer specs should no longer be pending in native mode.
- Do not require typed producer validation in this track.

### derivation

- Optional Hash.
- Nil for base facts.
- Must round-trip in Ruby mode, native mode, `to_h`, `from_h`, FileBackend,
  SegmentedFileBackend codecs where applicable.
- Expected shape:

```ruby
{
  name: "availability_snapshot",
  version: "1.0",
  descriptor_fact_id: "optional-id",
  source_fact_ids: ["fact-a", "fact-b"],
  source_hash: "optional-digest"
}
```

No derivation evaluator is required in this track.

## Acceptance

- Ruby `Fact.build` accepts `valid_time:`, `producer:`, and `derivation:`.
- Native `Fact.build` accepts and persists `valid_time`, `producer`, and
  `derivation`.
- `Fact#to_h` emits canonical keys:
  `transaction_time`, `valid_time`, `producer`, `derivation`.
- `Fact.from_h` accepts canonical keys and transitional legacy keys:
  `timestamp`, `term`.
- Existing call sites using `fact.timestamp` keep working through aliases.
- Existing call sites using `term:` keep working through compatibility keyword
  mapping if practical.
- Wire/protocol fact packets include canonical fields while preserving enough
  transitional compatibility for current specs.
- FileBackend and SegmentedFileBackend replay preserve the new fields.
- CompactDelta either preserves the new fields or clearly documents/specs which
  fields are intentionally omitted for compact history payloads. Prefer
  preservation where reasonable.
- Availability example can write snapshot facts with inline `derivation`.
- Full `packages/igniter-ledger` suite passes.

## Supervisor Cleanup

2026-05-03:

- Removed stale native Phase 2 pending around `Fact#producer`.
- `Protocol::Interpreter#write` and `write_fact` now accept `valid_time`,
  legacy `term`, `producer`, and `derivation` on ingress.
- Native Fact wrapper now returns frozen `value`, `producer`, and `derivation`
  metadata to match the Ruby fallback contract.
- Availability snapshot proof now persists inline `derivation` metadata on the
  snapshot fact.
- Added canonical Fact and legacy `timestamp`/`term` compatibility specs.

## Non-Goals

- No typed producer validation or producer indexes.
- No `valid_as_of` / `transaction_as_of` query API.
- No `key_schema`.
- No derivation descriptor evaluator.
- No Changefeed work.
- No Store-to-Ledger rename.

## Suggested Test Additions

- Fact canonical field spec.
- Fact legacy input compatibility spec.
- Native parity spec for `producer` and `derivation`.
- FileBackend round-trip spec for new fields.
- SegmentedFileBackend round-trip spec for new fields.
- Protocol packet spec for canonical field names.
- Availability proof update showing inline derivation on snapshot fact.

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/pre-v1-fact-model-migration
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
