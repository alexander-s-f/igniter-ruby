# Intelligent Ledger Research Index

Status date: 2026-05-02
Status: research horizon for future Package Agent slices
Supervisor: [Architect Supervisor / Codex]

## Purpose

Capture the next conceptual step beyond "store as durable accumulator".

The current package direction is already broader than storage: facts, histories,
receipts, replay, observability, durability, subscriptions, and changefeed
pressure. This directory explores what becomes possible when facts also carry
meaning, inference, derivation, and versioned behavior.

Working name for this horizon:

```text
Intelligent Ledger
```

This does not rename the package yet. The Store-to-Ledger naming migration is a
separate future slice.

## Core Thesis

```text
Accumulator
  facts -> replay -> current state

Intelligent Ledger
  facts -> inference -> derived facts -> transitions -> receipts -> explanation
```

The ledger should remember:

- what happened
- what it meant under the active rules
- what was derived from which facts
- what transitions occurred
- which rule/route version caused each result
- why the system made a decision

## Branches

| File | Branch | Question |
|------|--------|----------|
| [inference-datalog-plan.md](inference-datalog-plan.md) | Datalog-like inference | Can facts plus bounded rules produce explainable derived facts? |
| [reactive-derivations-plan.md](reactive-derivations-plan.md) | Reactive derivations | Can combinations of facts drive MobX/Railway-like computed projections? |
| [fact-routes-state-machines-plan.md](fact-routes-state-machines-plan.md) | Fact routes / state machines | Can facts deploy versioned declarative transitions without arbitrary code execution? |
| [ledger-boundaries-compaction-plan.md](ledger-boundaries-compaction-plan.md) | Ledger boundaries / timeframes | Can closed semantic containers preserve boundary truth while internal detail is compacted? |

## Shared Vocabulary

- **BaseFact**: durable fact written by a client or app boundary.
- **RuleFact**: versioned declarative rule stored in the ledger.
- **DerivedFact**: fact produced from other facts by a rule or derivation.
- **TransitionFact**: fact that records a state transition.
- **RouteFact**: versioned declarative route/trigger/state-machine definition.
- **EvaluationReceipt**: proof that a rule/route was evaluated.
- **DerivationReceipt**: proof that a derived fact came from specific source
  facts and rule versions.
- **TransitionReceipt**: proof that a state transition occurred under a specific
  route version.
- **LedgerBoundary**: closed semantic container over many facts; preserves inputs,
  outputs, source references, result hash, and receipts so internal details can
  later be retained, summarized, archived, or purged without losing boundary
  truth.

## Boundary Rule

Do not let facts execute arbitrary Ruby.

The safe target is:

```text
facts define data
facts may define declarative rules/routes
bounded evaluators interpret those rules/routes
every evaluation emits receipts
```

This keeps replay, determinism, security, and explanation possible.

## Suggested Agent Sequence

These are future slices, not current Slice 3 work.

1. Write a small conformance-only proof for Datalog-like inference over facts.
2. Add reactive derivation receipts over combinations of facts.
3. Add a minimal FactRoute state-machine proof.
4. Only after all three are understood, decide whether any of this becomes a
   package API, an extension package, or remains research.

## Handoff Format

Future Package Agent turns should use:

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/intelligent-ledger/<branch>
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
