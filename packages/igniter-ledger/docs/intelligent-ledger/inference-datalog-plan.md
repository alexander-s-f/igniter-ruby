# Datalog-Like Inference Plan

Status date: 2026-05-02
Status: research plan, not implementation commitment
Supervisor: [Architect Supervisor / Codex]

## Question

Can `igniter-ledger` support explainable inference over facts without importing a
full Prolog runtime or allowing arbitrary code execution?

## Claim

We want the useful part of Prolog/Datalog:

```text
known facts
bounded rules
queries
derived facts
explanations
```

We do not want unrestricted logic programming in the store server.

## Target Shape

```text
BaseFact
  price(symbol: "ETH", value: 1510)
  user_risk(user: "alex", level: "medium")

RuleFact
  expensive_asset if price.value > 1500
  alert_candidate if expensive_asset and user_risk.medium

DerivedFact
  expensive_asset(symbol: "ETH")
  alert_candidate(user: "alex", symbol: "ETH")

DerivationReceipt
  derived_fact_id
  rule_fact_id
  source_fact_ids
  evaluator_version
```

The most important feature is explanation:

```text
alert_candidate because:
  price#123 value=1510
  rule expensive_asset/v1
  user_risk#77 level=medium
  rule alert_candidate/v2
```

## Design Constraints

- Rules are data, not Ruby blocks.
- Rule evaluation is bounded.
- Rule versions are facts or descriptors.
- Derived outputs are facts or receipts, not hidden runtime state.
- Every derivation can be explained by source fact ids and rule ids.
- Recursive rules are out of scope for the first proof.
- Negation is out of scope until monotonic inference is understood.

## Minimal Rule Packet

Candidate packet:

```ruby
{
  kind: :rule,
  name: :expensive_asset,
  schema_version: 1,
  inputs: [
    { as: :price, store: :prices, where: { symbol: "$symbol" } }
  ],
  condition: {
    op: :gt,
    left:  { ref: "price.value" },
    right: 1500
  },
  emits: {
    store: :derived_signals,
    key: "$symbol:expensive_asset",
    value: { kind: :expensive_asset, symbol: "$symbol" }
  }
}
```

This is intentionally boring data. Later a nicer DSL may lower to this packet.

## Minimal Evaluator

First evaluator can be simple:

```text
for each changed fact
  find rules that reference its store
  load bounded candidate facts
  evaluate condition AST
  emit DerivedFact or no-op receipt
```

The evaluator should produce:

- accepted/rejected rule receipt
- no-op receipt when condition is false
- derivation receipt when a fact is emitted
- error receipt when rule packet is invalid

## Acceptance For First Agent Slice

- Add a small in-memory inference proof without changing public API.
- Register a rule descriptor/fact.
- Write source facts.
- Evaluate a bounded rule.
- Emit a derived fact.
- Emit a derivation receipt with source fact ids and rule id.
- Replay can reconstruct why the derived fact exists.
- Specs prove false condition creates no derived fact and records a no-op receipt.

## Non-Goals

- No full Prolog.
- No arbitrary Ruby execution.
- No unbounded recursion.
- No distributed inference.
- No query planner.
- No stable public DSL.

## Open Questions

- Should `RuleFact` live in the same fact log as user facts or a descriptor
  registry first?
- Are derived facts stored by default, or can some derivations remain virtual?
- How does rule invalidation work when a rule is superseded?
- How do we distinguish "derived under old rule" from "currently true"?
