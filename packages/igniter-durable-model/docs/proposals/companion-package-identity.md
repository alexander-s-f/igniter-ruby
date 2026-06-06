# Proposal: Companion Package Identity

Status: proposed
Owner: [Architect Supervisor / Codex]
Date: 2026-05-04

## Problem

`packages/igniter-companion` is no longer a good name for the package.

The word "Companion" now refers to several different things:

- old product/application sketches
- private home-lab companion work
- `examples/application/companion`
- the package currently named `igniter-companion`

That package is not really a companion application. It is the typed
application-facing model layer over durable storage shapes:

- `Record`
- `History`
- `Store`
- scopes
- descriptors from manifests
- receipts
- remote `LedgerClient` boundary

The name now makes architectural discussions harder because it hides the real
role of the package.

## Research Anchor

The old research in
`playgrounds/docs/experts/igniter-lang/igniter-lang-persistence.md` is still
directionally aligned with the current work.

Important old claims:

- persistence is a type property, not only infrastructure configuration
- durable shapes include `entity`, `History[T]`, `BiHistory[T]`,
  `OLAPPoint[T]`, await/saga logs, caches, and rule sets
- `Store[T]` is a language construct that can lower to backend requirements
- materialization is itself a contract
- consistency, partitioning, placement, and fanout are derived from typed access
  patterns

Current work has validated the first narrow runtime lane:

```text
Record        -> Store[T]
History       -> History[T]
scope         -> query/access path
receipt       -> normalized mutation result
manifest      -> generated model class
LedgerClient  -> remote protocol boundary
Ledger        -> current fact engine / WAL / changefeed
```

So the package is bigger than `igniter-ledger-client` and bigger than simple
database persistence. It is becoming the model layer where durable type shapes
are made usable from application code.

## Naming Options

### `igniter-ledger-client`

Rejected for this package.

This name already belongs to the low-level protocol and transport package:

```ruby
client.write(...)
client.query(...)
client.subscribe(...)
```

It should not know about Ruby domain classes, `Record`, `History`, scopes, or
manifest-generated models.

### `igniter-ledger-model`

Good short-term fit, but too tied to the current engine name.

It says: "typed model layer over Ledger." That is true today, but the older
language research leaves room for other storage shapes: entity, OLAP, saga
state, cache, rule stores, and materialization. Those may be implemented through
Ledger or alongside Ledger later.

Use this only if we intentionally decide Ledger is the universal durable kernel
and all higher storage shapes are ledger-backed.

### `igniter-persistence`

Accurate but slightly too narrow.

It captures durability, but not enough of the model semantics:

- typed shape vocabulary
- field/scopes/indexes/commands/relations metadata
- generated model classes
- materialization contracts
- consistency/access-path lowering

It is still acceptable as a public-friendly name, but it may undersell the
architecture.

### `igniter-model`

Rejected for now.

This is too broad and conflicts with existing Igniter core vocabulary:

```text
lib/igniter/model/
  Input
  Compute
  Composition
  Branch
  Collection
  Output
```

In core Igniter, "model" already means immutable graph node model. Reusing it
for durable application models would create a long-term namespace collision.

### `igniter-durable-model`

Recommended working name.

It says:

- this is a model layer, not only a client
- durability is the domain boundary
- it can cover `Store[T]`, `History[T]`, and later entity/OLAP/workflow state
- it does not overclaim ownership of all Igniter models
- it does not bind the public surface to Ledger internals

Potential namespace:

```ruby
Igniter::DurableModel::Record
Igniter::DurableModel::History
Igniter::DurableModel::Store
```

Compatibility namespace:

```ruby
Igniter::Companion::Record = Igniter::DurableModel::Record
Igniter::Companion::History = Igniter::DurableModel::History
Igniter::Companion::Store = Igniter::DurableModel::Store
```

## Proposed Layer Map

```text
examples/application/companion
  product/app proof, UI, materializer playground, setup packets

packages/igniter-durable-model
  typed durable model layer:
  Record, History, scopes, receipts, manifest-generated classes,
  later entity/OLAP/workflow state vocabulary

packages/igniter-ledger-client
  protocol and transports:
  write/read/append/replay/query/subscribe, HTTP/SSE/object dispatch

packages/igniter-ledger
  durable fact engine:
  WAL, facts, changefeed, query, compaction, boundary, storage backends

core igniter
  contract graph, compiler, runtime, effects, diagnostics
```

## Migration Strategy

Do not rename everything in one risky sweep while the subscription track is in
flight.

Recommended staged path:

1. Keep current package name until the active `on_scope` client boundary track
   lands.
2. Add `Igniter::DurableModel` namespace inside the existing package as the new
   canonical namespace.
3. Keep `Igniter::Companion` as a compatibility alias.
4. Update docs and examples to use `Igniter::DurableModel`.
5. Rename the gem/package directory from `igniter-companion` to
   `igniter-durable-model` once tests and examples are stable.
6. Leave a temporary `igniter-companion` shim if needed.
7. Reserve "Companion" exclusively for application/product examples.

## Decision

Use `igniter-durable-model` as the current recommended target name unless new
evidence shows that every durable shape should intentionally be branded as
Ledger.

Short form in discussion:

```text
Durable Model
```

Avoid:

```text
Companion package
Igniter Model
Ledger Client model layer
```
