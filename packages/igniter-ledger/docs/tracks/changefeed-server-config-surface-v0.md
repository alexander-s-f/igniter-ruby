# Track: Changefeed Server Config Surface v0

Status date: 2026-05-04
Status: done
Supervisor: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)

## Goal

Expose Changefeed production knobs through the LedgerServer configuration
surface.

The previous Changefeed slices made the buffer itself production-capable:
bounded replay, SSE, async fan-out, delivery policies, diagnostics, and alert
thresholds. But `LedgerServer` still constructs:

```ruby
@changefeed = ChangefeedBuffer.new
```

with default settings only.

This slice should make the server process configurable without leaking
Changefeed internals into transport handlers.

## Read First

Use the compact fresh-chat route:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. `docs/store-server-production-surface.md`
4. `docs/tracks/changefeed-delivery-policy-observability-v0.md`
5. `docs/tracks/changefeed-production-diagnostics-v0.md`
6. this track

Do not read the whole repository unless a failing test forces a wider search.

## Current Baseline

ChangefeedBuffer supports:

```ruby
ChangefeedBuffer.new(
  max_size: 1_000,
  subscriber_queue_size: 100,
  overflow: :drop_oldest,
  close_policy: :drain,
  diagnostic_ring_size: 100,
  alert_thresholds: {
    total_queued: 500,
    overflow_dropped_total: 10,
    failed_total: 1,
    queue_pressure_ratio: 0.8
  }
)
```

LedgerServer currently does not expose these knobs through:

- `ServerConfig`
- `LedgerServer.new(...)`
- `exe/igniter-ledger-server`
- docs/examples

## Scope

Add a server-level Changefeed configuration surface.

Suggested shape:

```ruby
config = Igniter::Store::ServerConfig.new(
  changefeed: {
    max_size: 2_000,
    subscriber_queue_size: 250,
    overflow: :drop_oldest,
    close_policy: :discard,
    diagnostic_ring_size: 500,
    alert_thresholds: {
      total_queued: 1_000,
      overflow_dropped_total: 25,
      failed_total: 1,
      queue_pressure_ratio: 0.8
    }
  }
)

server = Igniter::Store::LedgerServer.new(config: config)
```

Direct constructor should also support an override:

```ruby
server = Igniter::Store::LedgerServer.new(
  address: "127.0.0.1:7400",
  changefeed: { subscriber_queue_size: 10 }
)
```

Keyword args should take precedence over `ServerConfig`, following existing
LedgerServer convention.

## CLI Surface

Extend `exe/igniter-ledger-server` with explicit Changefeed options.

Suggested flags:

```text
--changefeed-max-size N
--changefeed-subscriber-queue-size N
--changefeed-overflow drop_oldest|drop_newest
--changefeed-close-policy drain|discard
--changefeed-diagnostic-ring-size N
--changefeed-alert-total-queued N
--changefeed-alert-overflow-dropped-total N
--changefeed-alert-failed-total N
--changefeed-alert-queue-pressure-ratio FLOAT
```

Do not add a config file parser in this slice.

## Validation

Validation should happen early.

Existing `ChangefeedBuffer` validates:

- overflow policy
- close policy
- alert threshold keys

This slice should add or preserve clear validation for:

- positive `max_size`
- positive `subscriber_queue_size`
- positive `diagnostic_ring_size`
- numeric threshold values where applicable
- ratio threshold between `0.0` and `1.0` if simple to enforce

If adding validation inside `ChangefeedBuffer` is the cleanest path, do it and
add focused specs. If not, validate in `ServerConfig` / CLI but keep behavior
consistent.

## Observability

`LedgerServer#observability_snapshot[:changefeed]` should reflect the configured
values through the existing `ChangefeedBuffer#snapshot` fields:

```text
max_size
subscriber_queue_size
overflow
close_policy
diagnostics
alerts
```

No new endpoint is required. `/v1/status` already receives this via the status
provider.

## Acceptance

- Full package test suite passes.
- `ServerConfig.new(changefeed: {...})` accepts known Changefeed config.
- `ServerConfig#to_h` includes `:changefeed`.
- Unknown `ServerConfig` keys still raise.
- `LedgerServer.new(config: config)` builds `ChangefeedBuffer` with config values.
- Direct `LedgerServer.new(changefeed: {...})` overrides config values.
- Invalid Changefeed values fail early with clear `ArgumentError`.
- CLI help includes the Changefeed options.
- CLI parsing builds the expected `ServerConfig` / server options without
  starting a long-running process in specs.
- `/v1/status` / `observability_snapshot` exposes configured Changefeed shape.
- Existing SSE/TCP/changefeed tests remain green.

## Non-Goals

- No Rust implementation.
- No durable subscriber registry.
- No auth/TLS.
- No external config file parser.
- No environment-variable matrix unless it falls out naturally.
- No WebSocket/webhook transport.
- No public v1 API promise.

## Suggested Files To Inspect

```text
lib/igniter/store/server_config.rb
lib/igniter/store/store_server.rb
lib/igniter/store/changefeed_buffer.rb
exe/igniter-ledger-server
spec/igniter/store/store_server_spec.rb
spec/igniter/store/server_production_surface_spec.rb
spec/igniter/store/changefeed_spec.rb
docs/store-server-production-surface.md
docs/progress.md
```

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-ledger/changefeed-server-config-surface-v0
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
