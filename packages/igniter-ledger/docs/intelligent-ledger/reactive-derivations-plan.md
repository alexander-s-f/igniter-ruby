# Reactive Derivations Plan

Status date: 2026-05-02
Status: research plan, not implementation commitment
Supervisor: [Architect Supervisor / Codex]

## Question

Can combinations of facts produce reactive, explainable projections similar to
MobX computed values or Railway-style step outputs, while staying ledger-native?

## Claim

The ledger can become a reactive memory if derived state is treated as first
class and explainable:

```text
source facts
  -> dependency graph
  -> derivation evaluator
  -> derived facts / projections
  -> derivation receipts
  -> changefeed notification
```

This should not become a hidden cache. Derived state must be inspectable and
replayable.

## Example

```text
Fact: sensor_temp(room: "lab", value: 38)
Fact: sensor_humidity(room: "lab", value: 90)

Derivation:
  heat_risk if temp > 35 and humidity > 80

DerivedFact:
  heat_risk(room: "lab", level: "high")

DerivationReceipt:
  output: heat_risk#900
  sources: [sensor_temp#123, sensor_humidity#124]
  derivation: heat_risk/v1
```

## Relationship To Existing Store Work

Existing pieces already point in this direction:

- `History[T]` stores durable event payloads.
- projections and derivation descriptors exist as metadata pressure.
- `ReadCache` already has invalidation concepts.
- Changefeed can notify downstream subscribers when derived facts change.

The missing piece is a package-level derivation receipt model that explains why
derived state exists.

## Target Components

### Derivation Descriptor

Defines inputs, join keys, condition, output shape, and materialization mode.

```ruby
{
  kind: :derivation,
  name: :heat_risk,
  inputs: [
    { as: :temp, store: :temperatures, key_by: :room },
    { as: :humidity, store: :humidity, key_by: :room }
  ],
  condition: {
    all: [
      { op: :gt, left: { ref: "temp.value" }, right: 35 },
      { op: :gt, left: { ref: "humidity.value" }, right: 80 }
    ]
  },
  output: {
    store: :derived_risks,
    key: "$room",
    value: { kind: :heat_risk, room: "$room", level: "high" }
  }
}
```

### Derivation Evaluator

Responsibilities:

- track dependency edges from source stores to derivations
- evaluate only affected keys/partitions when a fact changes
- emit derived facts or no-op receipts
- deduplicate unchanged derived outputs
- explain outputs through source fact ids

### Derivation Receipt

Minimum fields:

```ruby
{
  kind: :derivation_receipt,
  derivation: :heat_risk,
  derivation_version: 1,
  source_fact_ids: ["...", "..."],
  output_fact_id: "...",
  status: :derived,
  evaluated_at: 1_774_123_456.0
}
```

## Materialization Modes

Start with one mode, but name the future:

- `:materialized_fact`: output is written as a derived fact.
- `:virtual`: output is computed on demand.
- `:projection`: output updates a compact read model.

First slice should use `:materialized_fact` only.

## Acceptance For First Agent Slice

- Add a tiny derivation proof over two source stores.
- Source fact write can trigger derivation evaluation in a controlled test.
- Derived fact includes enough metadata to identify derivation/version.
- Derivation receipt lists source fact ids.
- Rewriting one source fact updates or supersedes derived output deterministically.
- No arbitrary Ruby blocks in persisted descriptor packets.

## Non-Goals

- No general join planner.
- No distributed derivation execution.
- No automatic app callback execution.
- No hidden mutable read model without receipts.
- No stable DSL promise.

## Open Questions

- Should derived facts carry `producer: { kind: :derivation, name:, version: }`?
- Should superseded derived facts be marked by a new fact or inferred by latest
  key semantics?
- Is derivation evaluation synchronous with write, queued through Changefeed, or
  configured per derivation?
- Does this live in `igniter-ledger` or an `igniter-ledger-rules` style package
  later?
