# Igniter Packages

Deprecated legacy material lives under private playgrounds and is reference-only.
This directory is the current package map for the pre-v1 Igniter framework.

## Active Platform Packages

- `igniter-contracts` - the contract graph kernel: DSL, compiler, runtime,
  diagnostics, effects, and contractable service semantics.
- `igniter-embed` - host-application bridge for registering contracts and
  observing/shadowing existing services without changing primary responses.
- `igniter-extensions` - optional packs, tooling, provenance, reactive,
  differential, invariant, and operational extension lanes.
- `igniter-ledger` - Ledger substrate for facts, histories, receipts, WAL,
  replay, changefeed, Ledger Open Protocol, compaction activity, and intelligent
  boundary proofs. Still pre-v1/POC, but now an active platform lane.
- `igniter-ledger-client` - protocol-first client boundary for Store/Ledger
  users; owns envelopes, transport adapters, errors, and future pool/retry
  policy without embedding the storage engine.
- `igniter-durable-model` - typed Record/History facade over `igniter-ledger`,
  carrying app-facing persistence pressure back into Store/Ledger design.
- `igniter-application` - contracts-native app runtime: manifests, providers,
  services, credentials, agents, sessions, snapshots, and boot/shutdown plans.
- `igniter-web` - operator and interaction surfaces for receipts, dashboards,
  event streams, approval gates, investigation views, and app-local mounts.
- `igniter-ai` - AI provider and execution lane.
- `igniter-agents` - agent runtime lane for runs, turns, traces, state, and
  approval-oriented execution.
- `igniter-cluster` - distributed runtime seams for capability-aware peers,
  planning, routing, ownership, health, and failover experiments.
- `igniter-hub` - hub/synchronization lane for package-level coordination and
  eventually externalized control surfaces.
- `igniter-mcp-adapter` - MCP-facing transport surface for tools, reads, and
  operator introspection.

## Status

All packages are pre-v1. API stability, transport guarantees, and production
deployment promises should be checked in the owning package README and current
track docs before depending on them.

The Ruby Framework `0.5.2` release covered the currently published Ruby gem
line: `igniter`, `igniter-contracts`, `igniter-extensions`, `igniter-embed`,
`igniter-ledger-client`, and `igniter-ledger`. Other package directories may be
active source lanes or proof packages, but they are not implied by that release.

`igniter-ledger` and `igniter-durable-model` are no longer parked as passive research
packages. They remain experimental in API shape, but they are active foundation
work for Ledger-backed companion systems.

## Deferred / Conditional Work

- Rebuild `igniter-server` only if an adapter surface is still needed after
  `igniter-ledger`, `igniter-web`, MCP, and app-local mounts settle.

Before adding provider clients, agent runtime logic, or application examples,
open a focused design/implementation slice. The old dev-plan material was not
bulk-carried into this split-era baseline.
