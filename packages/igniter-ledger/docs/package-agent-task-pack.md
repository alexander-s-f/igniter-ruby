# igniter-ledger Package Agent Task Pack

Status date: 2026-05-03
Status: mostly executed sequential task pack, not a stable public API promise
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Purpose

This document packages three large follow-up slices for the Package Agent. The
agent should take them sequentially, one vertical slice per turn when possible.
Small polish fixes and narrow regressions can stay with the Architect
Supervisor/Codex loop; this pack is meant for larger context-heavy work.

## Current Baseline

- Ledger Open Protocol exists as the package-level operation model.
- `MCPAdapter` exists and can run read-only local tools plus remote dispatch.
- `LedgerServer` has an observability baseline: metrics snapshots, health
  snapshots, structured events, connection/subscription counters, request/error
  counters, byte counters, and alerts.
- Segmented storage has metadata/conformance pressure: format, compression,
  partition/segment shape, manifest facts, and quarantine receipts.
- Current package verification baseline after the latest local fix:
  `bundle exec rspec spec` in `packages/igniter-ledger` passes with
  622 examples, 0 failures.

## Operating Rules

- Prefer vertical slices over isolated helper changes.
- Start fresh Package Agent chats from `docs/package-agent-onboarding.md`, then
  read `docs/progress.md` and the single assigned track.
- Keep Ledger Open Protocol as the semantic center. HTTP, MCP, and legacy server
  commands should be transports/views over the protocol, not competing models.
- Do not expose runtime database/storage implementation details in public API
  surfaces.
- Keep backward compatibility only where it protects existing package tests or
  app-local proofs; pre-v1 weak shapes may be replaced when the target shape is
  clear.
- Each completed slice should end with a compact handoff: files changed, tests
  run, behavior added, unresolved risks.

## Slice 1: Store Observatory Convergence

Goal: converge server observability across Ledger Open Protocol, HTTP, MCP, and
legacy server command paths.

The recent `LedgerServer` work created useful observability primitives, but they
still need one coherent package-facing shape. The next step is to make health,
metrics, alerts, and status available through the same conceptual contract no
matter which transport reads them.

Suggested implementation direction:

- Define one canonical observability result shape. Prefer a compact structure
  around `status`, `uptime`, `metrics`, `alerts`, `storage`, and `server`.
- Decide whether the protocol operation should be `server_status`,
  `observability_snapshot`, or both with one aliasing the other.
- Keep the existing legacy `"server_status"` operation working if tests or app
  usage already depend on it.
- Expose the same canonical shape through HTTP health/status endpoints.
- Add MCP read-only observability tools over the same backend/protocol path.
- Add conformance specs showing that protocol, HTTP, MCP, and legacy server
  views agree on the important fields.

Acceptance:

- A single source of truth drives observability snapshots.
- MCP observability does not bypass the protocol/backend boundary.
- HTTP exposes compact health/status data without leaking storage internals.
- Alerts include storage-level facts such as `quarantine_receipt_count`.
- Specs cover success, degraded/error state, alert thresholds, and request id
  preservation where applicable.
- Docs are updated in the relevant proposal/status files.

Non-goals:

- Do not add Prometheus/OpenTelemetry dependencies yet.
- Do not build a dashboard UI in this slice.
- Do not turn observability into a general event database.

## Slice 2: Storage Durability Contract

Goal: make the durability guarantees of segmented storage explicit and testable,
especially for compact/compressed formats.

The current segmented storage direction is promising, but before using it for
high-volume sensor streams we need a crisp answer to: "what survives a crash,
when, and with what receipt?" This is the contract that lets us benchmark and
optimize honestly.

Suggested implementation direction:

- Document current durability behavior for `jsonl`, `compact_delta_zlib`, and
  any other active format.
- Identify whether small unflushed batches can be lost under
  `compact_delta_zlib`; if yes, make the loss window explicit.
- Introduce an explicit flush/checkpoint policy if needed:
  `flush_on_write`, `flush_every_n`, `flush_interval`, `close/checkpoint`, or a
  similar package-native spelling.
- Consider returning a durability receipt that distinguishes accepted,
  buffered, flushed, checkpointed, and compacted facts.
- Add crash/reopen specs for sub-batch writes, full batches, quarantined
  segments, manifest facts, and fact counts.
- Feed the result back into the storage benchmark plan so speed/size tests
  compare policies, not only formats.

Acceptance:

- Storage docs state the durability contract in plain language.
- Specs prove reopen behavior for the selected flush/checkpoint policy.
- The package can explain the tradeoff between throughput, file size, and loss
  window.
- No hidden in-memory-only success path is presented as durable persistence.
- Benchmark plan includes durability policy dimensions.

Non-goals:

- Do not implement encryption in this slice unless it falls out naturally from
  the format boundary.
- Do not optimize for terabyte scale before the durability semantics are clear.
- Do not introduce a database dependency.

## Slice 3: Store Server Production Surface

Goal: harden the server surface around operational use without turning it into a
large platform.

Once observability is coherent and durability is explicit, the server needs a
small production-ready shell: readiness, graceful drain state, recent events,
threshold configuration, and predictable error reporting.

Suggested implementation direction:

- Extend server configuration for alert thresholds, max recent events, slow
  operation threshold, health exposure, and log format where needed.
- Add a bounded recent-events ring buffer fed by structured server events.
- Track slow operations and surface them as metrics/alerts.
- Distinguish health from readiness:
  health answers "is the process alive?"
  readiness answers "should traffic be routed here?"
- Add a draining/shutdown state if the current lifecycle supports it cleanly.
- Consider HTTP endpoints such as `/v1/health`, `/v1/ready`, `/v1/metrics`, and
  optionally `/v1/events/recent`, backed by the same observability snapshot.
- Keep wire errors structured with request ids and stable error codes.

Acceptance:

- Operators can inspect health, readiness, metrics, alerts, and recent events.
- Server lifecycle states are visible and covered by specs.
- Slow operation thresholds can be configured and tested.
- Connection limit rejection remains observable.
- Docs describe the intended production surface and what is intentionally not
  included yet.

Non-goals:

- Do not add auth/TLS in this slice unless required by an existing package
  boundary.
- Do not add external metrics exporters yet.
- Do not design a cluster manager here.

## Handoff Format

At the end of each Package Agent turn, respond with:

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/<slice-name>
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

Use `[D]` for decisions, `[S]` for shipped implementation, `[T]` for tests, and
`[R]` for risks or recommendations. Keep it compact enough that the Architect
Supervisor can merge the result into the next loop without rereading all docs.
