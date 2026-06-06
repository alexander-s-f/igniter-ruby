# Igniter

Igniter is a pre-v1 Ruby framework for building contracts-native applications,
companions, and agent-aware systems.

At the center is a small contract graph kernel: validated inputs, computations,
effects, outputs, diagnostics, and execution plans. Around that kernel Igniter is
growing into a platform for:

- embedding contract behavior into existing applications
- observing and shadowing legacy services without changing production responses
- storing immutable facts, histories, receipts, and replayable decisions
- building companion apps beside existing systems of record
- exposing operator surfaces, streams, MCP tools, and eventually cluster peers
- giving AI agents evidence, receipts, and approval boundaries before authority

The short version:

```text
Contracts
  -> Embed migration bridge
  -> Store / Ledger facts and receipts
  -> Ledger Client protocol boundary
  -> Companion typed Record/History facade
  -> Application + Web operator surfaces
  -> Agents / AI / Cluster / Hub runtime lanes
```

## Status

Igniter is pre-v1. There is no backward-compatibility promise and no stable
public API guarantee yet. That is intentional: weak shapes should still be
replaced quickly while the better architecture is visible.

The project is now large enough to be treated as a framework/platform, but its
surface is still being actively shaped by real application pressure. Current
proofs are strongest in:

- contract graph authoring and execution
- host-local embedding and contractable shadowing
- Store/Ledger facts, WAL, replay, changefeeds, compaction activity, and
  read-only protocol surfaces
- application/web package structure and operator-oriented surfaces
- early agents, AI, hub, and cluster package lanes

Use package READMEs, runnable examples, and track docs to evaluate current
capability. Production-grade guarantees and compatibility policy belong after
v1.

Released Ruby gems are the package surface that has been cut and published.
Other package lanes in this repository may be active, local, or proof-only even
when they appear in the framework map.

## Platform Lanes

### `igniter-contracts`

The kernel: DSL authoring, graph compilation, runtime execution, diagnostics,
effects, and the core `Contractable` service protocol used inside contracts.

### `igniter-embed`

The migration bridge for existing applications. It registers host-local
contracts and wraps opaque services with `contractable` observation/shadowing:

```text
legacy primary result
  -> returned unchanged
  -> optional candidate/shadow execution
  -> normalized comparison
  -> observation / divergence receipts
```

This is the safest first path for Rails and other host apps.

### `igniter-ledger`

The Ledger substrate: immutable facts, `Store[T]` and `History[T]` experiments,
causation, current/time-travel reads, access paths, WAL durability, changefeed,
Ledger Open Protocol, LedgerServer, compaction lifecycle, and intelligent-ledger
boundary proofs.

It is still a POC package, but it is no longer just "persistence research"; it
is the event memory and receipt substrate for companion systems.

### `igniter-ledger-client`

The protocol-first client boundary for Ledger users. It owns request/response
envelopes, transports, errors, and future pooling/retry/backpressure policy
without embedding the storage engine.

### `igniter-companion`

Typed application-facing `Record` / `History` facade over `igniter-ledger`.
It turns raw facts into ergonomic app objects while applying pressure back onto
Store capabilities such as scopes, partitions, receipts, manifests, and typed
storage semantics.

### `igniter-application`

Contracts-native application runtime: app manifests, providers, services,
credentials, agents, sessions, snapshots, boot/shutdown plans, and embedded host
activation paths.

### `igniter-web`

Operator and interaction surfaces: receipt/report views, event streams,
dashboards, human approval gates, investigation workspaces, and app-local web
mounts. It is not trying to replace a Rails admin UI.

### `igniter-agents` and `igniter-ai`

Agent and AI runtime lanes: runs, turns, traces, serializable state, provider
registration, and the promotion ladder from observe-only to human-approved
authority.

### `igniter-cluster` and `igniter-hub`

Distributed and sync lanes: capability-aware peers, ownership, leases, health,
failover, admission/trust, and hub-style synchronization. These should emerge
from real partitioned domains rather than "distributed everything".

### `igniter-mcp-adapter`

Transport-facing MCP surface for exposing tools, protocol reads, and operator
introspection.

## Small Contract Example

```ruby
require "igniter"

environment = Igniter.with

result = environment.run(inputs: { order_total: 100, country: "UA" }) do
  input :order_total
  input :country

  compute :vat_rate, depends_on: [:country] do |country:|
    country == "UA" ? 0.2 : 0.0
  end

  compute :gross_total, depends_on: %i[order_total vat_rate] do |order_total:, vat_rate:|
    order_total * (1 + vat_rate)
  end

  output :gross_total
end

result.output(:gross_total)
# => 120.0
```

## Companion Direction

Igniter is being shaped by real application pressure such as Spark CRM:

```text
Existing app remains the system of record
  -> Igniter Embed observes/shadows risky services
  -> Igniter Ledger records facts and receipts
  -> Ledger boundaries close semantic decisions
  -> Web/Agents explain, review, and recommend
```

This is the current strategic pattern: do not rewrite a production app into
Igniter. Build an Igniter companion beside it, move event-heavy and
explanation-heavy responsibilities behind explicit facts, receipts, boundaries,
and approval gates.

## What Is Not Promised Yet

- Stable v1 API compatibility.
- A production database adapter abstraction.
- Igniter-Lang compiler/parser/runtime compatibility beyond the additive,
  report-only Lang foundation currently documented for `igniter-contracts`.
- Remote mutating Store operations for compaction/prune/purge.
- Cluster consensus or deployment guarantees.
- AI authority without receipts, policies, replay, and human approval paths.

## Repository Map

- [docs/](./docs/README.md) — documentation portal
- [docs/guide/](./docs/guide/README.md) — user-facing guide
- [docs/concepts/](./docs/concepts/README.md) — mental models and vocabulary
- [docs/dev/](./docs/dev/README.md) — architecture and package boundaries
- [examples/](./examples/README.md) — runnable examples
- [packages/](./packages/README.md) — package list and local package docs
- [playgrounds/](./playgrounds/README.md) — private/local-first experiments and history

## Package Docs

- [igniter-contracts](./packages/igniter-contracts/README.md)
- [igniter-extensions](./packages/igniter-extensions/README.md)
- [igniter-embed](./packages/igniter-embed/README.md)
- [igniter-ledger](./packages/igniter-ledger/README.md)
- [igniter-ledger-client](./packages/igniter-ledger-client/README.md)
- [igniter-companion](./packages/igniter-companion/README.md)
- [igniter-application](./packages/igniter-application/README.md)
- [igniter-web](./packages/igniter-web/README.md)
- [igniter-agents](./packages/igniter-agents/README.md)
- [igniter-ai](./packages/igniter-ai/README.md)
- [igniter-cluster](./packages/igniter-cluster/README.md)
- [igniter-hub](./packages/igniter-hub/README.md)
- [igniter-mcp-adapter](./packages/igniter-mcp-adapter/README.md)

## Working Principle

Igniter evolves through a tight loop:

```text
real app pressure
  -> proof-local experiment
  -> receipt-backed package primitive
  -> protocol/read surface
  -> docs compression
  -> next pressure
```

That loop is why some docs live beside packages, some live in public guide/dev
sections, and older long-form research is compressed into `playgrounds/docs/`
instead of being used as public onboarding.
