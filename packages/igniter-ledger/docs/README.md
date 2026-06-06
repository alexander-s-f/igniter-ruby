# igniter-ledger — Docs

Implementation specifications, progress records, and track handoffs for the
`igniter-ledger` package.

Status: active pre-v1 Ledger substrate work. Prefer compact current-state docs
first; use track docs for implementation history and acceptance evidence.

Rename note: current user-facing package name is `igniter-ledger`. Legacy
`igniter-store` require/CLI entrypoints remain compatibility shims only; the
internal `Igniter::Store` namespace and `:igniter_store` protocol token are
intentional pre-v1 carryovers until a later deep-rename phase.

## Fast Reading Path

1. [progress.md](progress.md) — compact current implementation status.
2. [pre-v1-core-model-proposal.md](pre-v1-core-model-proposal.md) — current
   core model pressure before v1.
3. [open-protocol.md](open-protocol.md) — Ledger Open Protocol vocabulary.
4. [server-api-proposal.md](server-api-proposal.md) — server/API layer above
   the protocol.
5. [intelligent-ledger/README.md](intelligent-ledger/README.md) — horizon for
   inference, derivations, routes, and Ledger boundaries.

## Core Specs And Proposals

| File | Description |
|------|-------------|
| [open-protocol.md](open-protocol.md) | Standalone Ledger Open Protocol proposal |
| [server-api-proposal.md](server-api-proposal.md) | Server/API layer above Ledger Open Protocol |
| [mcp-adapter-proposal.md](mcp-adapter-proposal.md) | MCP agent adapter over Ledger Open Protocol |
| [pre-v1-core-model-proposal.md](pre-v1-core-model-proposal.md) | Fact model, bi-temporal time, derivation, producer, and core-v1 pressure |
| [storage-format-benchmark-plan.md](storage-format-benchmark-plan.md) | Compact storage, partitioning, encryption, and benchmark plan |
| [segmented-storage-hardening-proposal.md](segmented-storage-hardening-proposal.md) | Next hardening slice for segmented WAL storage |
| [storage-metadata-conformance-proposal.md](storage-metadata-conformance-proposal.md) | Conformance slice for storage metadata across backend/protocol/wire/MCP |
| [rust-native-data-plane-plan.md](rust-native-data-plane-plan.md) | Rust/native data-plane migration plan for storage, codecs, indexes, and delivery |
| [changefeed-events-plan.md](changefeed-events-plan.md) | Changefeed/events subsystem plan over committed facts |
| [poc-specification.md](poc-specification.md) | Contract-native store proof-of-concept spec |
| [poc-specification.ru.md](poc-specification.ru.md) | То же, на русском |
| [server-model.md](server-model.md) | LedgerServer + LedgerNetworkBackend design |
| [server-model.ru.md](server-model.ru.md) | То же, на русском |
| [relations-specification.md](relations-specification.md) | Contract-persistence relations design |
| [companion-convergence.md](companion-convergence.md) | Companion↔Store convergence specification |
| [progress.md](progress.md) | Implementation progress summary |

## Track Families

| File | Description |
|------|-------------|
| [intelligent-ledger/README.md](intelligent-ledger/README.md) | Intelligent Ledger research index: inference, derivations, and fact routes |
| [tracks/pre-v1-fact-model-migration.md](tracks/pre-v1-fact-model-migration.md) | Package Agent track for the P0 Fact model migration |
| [tracks/ledger-fact-id-index-v0.md](tracks/ledger-fact-id-index-v0.md) | Fact id lookup/index support |
| [tracks/ledger-relation-edge-redirect-projection-v0.md](tracks/ledger-relation-edge-redirect-projection-v0.md) | Relation edge redirect projection |
| [tracks/ledger-cleanup-execution-and-edge-index-v0.md](tracks/ledger-cleanup-execution-and-edge-index-v0.md) | Cleanup execution and edge index |
| [tracks/ledger-boundary-availability-proof-v0.md](tracks/ledger-boundary-availability-proof-v0.md) | Availability snapshot boundary proof |
| [tracks/ledger-boundary-source-fact-provenance-v0.md](tracks/ledger-boundary-source-fact-provenance-v0.md) | Boundary source fact provenance |
| [tracks/ledger-boundary-settlement-proof-v0.md](tracks/ledger-boundary-settlement-proof-v0.md) | Boundary settlement proof |
| [tracks/ledger-boundary-reference-redirects-v0.md](tracks/ledger-boundary-reference-redirects-v0.md) | References redirected through boundaries |
| [tracks/ledger-boundary-hydration-recovery-v0.md](tracks/ledger-boundary-hydration-recovery-v0.md) | Hydration and recovery after boundary closure |
| [tracks/ledger-boundary-cleanup-reference-guards-v0.md](tracks/ledger-boundary-cleanup-reference-guards-v0.md) | Cleanup guards for boundary references |
| [tracks/ledger-boundary-physical-purge-barrier-v0.md](tracks/ledger-boundary-physical-purge-barrier-v0.md) | Physical purge barrier for closed boundaries |
| [tracks/compaction-lifecycle-unification-v0.md](tracks/compaction-lifecycle-unification-v0.md) | Unified compact/prune/purge vocabulary |
| [tracks/compaction-activity-protocol-surface-v0.md](tracks/compaction-activity-protocol-surface-v0.md) | Compaction activity protocol/read surface |
| [tracks/contractable-receipt-ledger-sink-v0.md](tracks/contractable-receipt-ledger-sink-v0.md) | Durable Store/Ledger sink for Embed contractable observation/event receipts |
| [tracks/ledger-rename-hardening-compatibility-audit-v0.md](tracks/ledger-rename-hardening-compatibility-audit-v0.md) | Public rename hardening, compatibility tests, token audit map, and deep-rename plan |
| [tracks/ledger-client-append-protocol-boundary-v0.md](tracks/ledger-client-append-protocol-boundary-v0.md) | First-class protocol append op for LedgerClient and history/event consumers |
| [tracks/ledger-tbackend-adapter-descriptor-package-v0.md](tracks/ledger-tbackend-adapter-descriptor-package-v0.md) | Metadata-only Ledger TBackend adapter descriptor value object and diagnostics |
| [tracks/changefeed-events-v0.md](tracks/changefeed-events-v0.md) | Package Agent track for the first Changefeed events subsystem slice |
| [tracks/changefeed-ordering-replay-v0.md](tracks/changefeed-ordering-replay-v0.md) | Package Agent track for Changefeed ordering and replay cursor semantics |
| [tracks/changefeed-sse-events-v0.md](tracks/changefeed-sse-events-v0.md) | Package Agent track for SSE `/v1/events` over Changefeed replay/live push |
| [tracks/changefeed-async-fanout-v0.md](tracks/changefeed-async-fanout-v0.md) | Package Agent track for Ruby async fan-out with per-subscriber queues |
| [tracks/changefeed-delivery-policy-observability-v0.md](tracks/changefeed-delivery-policy-observability-v0.md) | Package Agent track for Changefeed delivery policy and observability hardening |
| [tracks/changefeed-production-diagnostics-v0.md](tracks/changefeed-production-diagnostics-v0.md) | Changefeed diagnostics and alerts |
| [tracks/changefeed-server-config-surface-v0.md](tracks/changefeed-server-config-surface-v0.md) | Changefeed server/CLI config surface |

## Agent And Docs Workflow

| File | Description |
|------|-------------|
| [docs-workflow.md](docs-workflow.md) | Documentation workflow for research, proposals, tracks, and final docs |
| [package-agent-onboarding.md](package-agent-onboarding.md) | Compact fresh-chat entrypoint for Package Agent |
| [package-agent-task-pack.md](package-agent-task-pack.md) | Sequential large-slice task pack for Package Agent |
| [architect-supervisor-backlog.md](architect-supervisor-backlog.md) | Small local polish backlog for Architect Supervisor / Codex |

## Reviews

| File | Description |
|------|-------------|
| [reviews/README.md](reviews/README.md) | External and cross-agent review notes before they become proposals or tracks |

## Research Iterations

| File | Description |
|------|-------------|
| [research/store-iterations.md](research/store-iterations.md) | Store design iteration history |
| [research/store-iterations.ru.md](research/store-iterations.ru.md) | То же, на русском |
| [research/sync-hub-iterations.md](research/sync-hub-iterations.md) | Sync-hub design iteration history |
| [research/sync-hub-iterations.ru.md](research/sync-hub-iterations.ru.md) | То же, на русском |
