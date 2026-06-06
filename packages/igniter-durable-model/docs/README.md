# igniter-durable-model — Durable Model Docs

Status reports, manifest glossary, and performance signals for the Durable Model
layer. The package is `igniter-durable-model`; the canonical Ruby namespace is
`Igniter::DurableModel`, with `Igniter::Companion` kept as a compatibility
alias.

| File | Description |
|------|-------------|
| [current-status.md](current-status.md) | Durable Model implementation current status summary |
| [app-status.md](app-status.md) | Durable Model persistence app status |
| [manifest-glossary.md](manifest-glossary.md) | Persistence manifest field glossary |
| [performance.md](performance.md) | Contract performance signal notes |
| [proposals/companion-package-identity.md](proposals/companion-package-identity.md) | Proposal to rename/reframe the package as Durable Model instead of Companion |
| [tracks/durable-model-namespace-adoption-v0.md](tracks/durable-model-namespace-adoption-v0.md) | Track for introducing `Igniter::DurableModel` before physical package rename |
| [tracks/durable-model-package-rename-v0.md](tracks/durable-model-package-rename-v0.md) | Track for physically renaming the package to `igniter-durable-model` with Companion compatibility |
| [tracks/durable-model-public-reference-cleanup-v0.md](tracks/durable-model-public-reference-cleanup-v0.md) | Proposed cleanup track for current docs/examples after the Durable Model package rename |
| [tracks/durable-model-client-history-partition-replay-v0.md](tracks/durable-model-client-history-partition-replay-v0.md) | Proposed track for client-backed History partition replay through Ledger Client replay filters |
| [tracks/durable-model-client-relation-resolve-v0.md](tracks/durable-model-client-relation-resolve-v0.md) | Proposed track for client-backed relation auto-wire and typed resolve through Ledger descriptors |
| [tracks/durable-model-client-projection-descriptor-v0.md](tracks/durable-model-client-projection-descriptor-v0.md) | Completed track for client-backed projection metadata descriptors and read-only scatter snapshots |
| [tracks/durable-model-client-provenance-introspection-v0.md](tracks/durable-model-client-provenance-introspection-v0.md) | Completed read-only provenance/lineage protocol and client-backed causation chains |
| [tracks/durable-model-command-effect-descriptor-parity-v0.md](tracks/durable-model-command-effect-descriptor-parity-v0.md) | Completed metadata-only command/effect descriptors through Ledger metadata |
| [tracks/durable-model-command-intent-boundary-v0.md](tracks/durable-model-command-intent-boundary-v0.md) | Completed pure command intent objects at the app boundary |
| [tracks/durable-model-command-operation-plan-v0.md](tracks/durable-model-command-operation-plan-v0.md) | Completed non-mutating command operation planning and dry-run validation |
| [tracks/durable-model-command-activity-projection-v0.md](tracks/durable-model-command-activity-projection-v0.md) | Completed app-safe command activity projection without persistence |
| [tracks/durable-model-command-activity-history-v0.md](tracks/durable-model-command-activity-history-v0.md) | Completed explicit app-safe command activity history persistence |
| [tracks/durable-model-command-apply-boundary-v0.md](tracks/durable-model-command-apply-boundary-v0.md) | Completed explicit app-boundary command application without Ledger-side execution |
| [tracks/durable-model-command-policy-gate-v0.md](tracks/durable-model-command-policy-gate-v0.md) | Completed explicit app-owned policy/capability gate before command application |
| [tracks/durable-model-command-lifecycle-v0.md](tracks/durable-model-command-lifecycle-v0.md) | Completed command lifecycle read model over intent, plan, policy, apply, and audit |
| [tracks/durable-model-command-flow-v0.md](tracks/durable-model-command-flow-v0.md) | Completed app-owned command flow orchestrator over intent, plan, policy, audit, apply, and lifecycle |
| [tracks/durable-model-command-flow-temporal-slices-v0.md](tracks/durable-model-command-flow-temporal-slices-v0.md) | Completed temporal command-flow slice read model over command activity history |
| [tracks/durable-model-command-flow-monitors-v0.md](tracks/durable-model-command-flow-monitors-v0.md) | Completed command-flow monitor evaluation over temporal slices |
| [tracks/durable-model-command-flow-operational-views-v0.md](tracks/durable-model-command-flow-operational-views-v0.md) | Completed named operational views over command-flow slices and monitors |
| [tracks/durable-model-command-flow-view-pinning-v0.md](tracks/durable-model-command-flow-view-pinning-v0.md) | Completed explicit pinning of operational views into reproducible decision evidence |
| [tracks/durable-model-command-flow-decision-history-v0.md](tracks/durable-model-command-flow-decision-history-v0.md) | Completed explicit history persistence and replay for command-flow view decisions |
| [tracks/durable-model-command-flow-decision-review-v0.md](tracks/durable-model-command-flow-decision-review-v0.md) | Completed read model for summarizing persisted command-flow decisions |
| [tracks/durable-model-command-flow-evidence-profile-v0.md](tracks/durable-model-command-flow-evidence-profile-v0.md) | Completed portable app-safe evidence profile over command-flow views, pins, decisions, and reviews |
| [tracks/durable-model-command-flow-evidence-export-v0.md](tracks/durable-model-command-flow-evidence-export-v0.md) | Completed deterministic app-safe export bundle for command-flow evidence profiles |
| [tracks/durable-model-command-flow-evidence-archive-v0.md](tracks/durable-model-command-flow-evidence-archive-v0.md) | Completed explicit archive and verification for command-flow evidence exports |
| [tracks/companion-ledger-client-remote-boundary-v0.md](tracks/companion-ledger-client-remote-boundary-v0.md) | Track for accepting `LedgerClient` as Companion's preferred remote Ledger boundary |
| [tracks/companion-ledger-client-scope-query-boundary-v0.md](tracks/companion-ledger-client-scope-query-boundary-v0.md) | Proposed next track for remote Companion scopes over `LedgerClient#query` |
| [tracks/companion-ledger-client-scope-subscriptions-v0.md](tracks/companion-ledger-client-scope-subscriptions-v0.md) | Proposed next track for remote Companion `on_scope` over Ledger Client events |
