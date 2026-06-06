# Fact Routes And State Machines Plan

Status date: 2026-05-02
Status: research plan, not implementation commitment
Supervisor: [Architect Supervisor / Codex]

## Question

Can facts deploy versioned declarative micro-routes that turn the ledger into an
explainable state machine without permanently binding behavior into code?

## Intuition

A fact should be able to declare behavior like:

```text
state: A
wait: fact price > 1500
then: state B
```

But this must remain declarative and replayable. The fact should not execute
arbitrary code. A bounded evaluator should interpret a versioned route packet and
emit transition receipts.

## Target Shape

```text
RouteFact
  name: eth_breakout_route
  target: position:eth
  version: 3
  initial_state: watching
  transitions:
    watching -- price > 1500 --> breakout
    breakout -- risk > high --> reduce

Incoming Fact
  price(symbol: "ETH", value: 1510)

TransitionFact
  target: position:eth
  from: watching
  to: breakout

TransitionReceipt
  route_fact_id
  route_version
  source_fact_ids
  previous_state_fact_id
  transition_fact_id
```

This gives historical behavior:

- which route version was active
- which facts woke it up
- why the state changed
- when a route was deployed, superseded, or disabled

## Candidate Route Packet

```ruby
{
  kind: :fact_route,
  name: :eth_breakout_route,
  target: "position:eth",
  schema_version: 1,
  initial_state: :watching,
  transitions: [
    {
      from: :watching,
      to: :breakout,
      when: {
        fact: { store: :prices, where: { symbol: "ETH" } },
        condition: { op: :gt, left: { ref: "fact.value" }, right: 1500 }
      }
    }
  ]
}
```

The DSL can come later. The packet should be the first artifact.

## Route Lifecycle

Route behavior must be history-aware:

```text
deploy route v1
facts arrive
transition receipts reference v1
deploy route v2
new facts use v2
old transition history still explains through v1
disable route
future facts no longer trigger transitions
```

This is the core advantage over code-only state machines.

## Safety Constraints

- Route packets are data, not executable Ruby.
- Conditions use a bounded condition AST.
- Evaluator has step limits.
- Route deployment emits a receipt.
- Route supersession is explicit.
- Transition output is a fact or receipt.
- Replay can reconstruct transitions from route facts and source facts.

## Relationship To Changefeed

FactRoute evaluation should likely subscribe to committed facts through
Changefeed:

```text
fact committed
  -> change event
  -> route evaluator checks matching routes
  -> transition fact/receipt
  -> changefeed emits transition
```

For the first proof, synchronous in-process evaluation is acceptable. Durable
async routing should wait until Changefeed semantics are clearer.

## Acceptance For First Agent Slice

- Add a minimal route packet parser/validator.
- Deploy one route as a descriptor or fact.
- Write a source fact that satisfies the condition.
- Emit a transition fact.
- Emit a transition receipt that references route version and source fact id.
- Write a source fact that does not satisfy the condition and produce no
  transition, with optional no-op receipt.
- Supersede route v1 with v2 and prove new transitions reference v2.

## Non-Goals

- No arbitrary Ruby execution.
- No workflow engine.
- No external timers in the first proof.
- No distributed state machine.
- No stable DSL.
- No irreversible side effects from route evaluation.

## Open Questions

- Should route state be represented as latest fact by target key?
- Should no-op evaluations be stored or only counted?
- How do time-based waits work: timer facts, scheduler adapter, or external
  clock source?
- Can routes emit commands, or only transition facts in the first version?
- Is FactRoute part of `igniter-ledger`, an extension, or future Ledger package?
