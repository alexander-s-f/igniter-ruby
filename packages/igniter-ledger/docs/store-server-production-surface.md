# Store Server Production Surface

**Package:** igniter-ledger
**Status:** active
**Date:** 2026-05-02

## What this document covers

The operational shell around `LedgerServer`: lifecycle states, readiness, recent
events, slow operation tracking, and HTTP endpoints for operator tooling.

---

## Lifecycle states

`LedgerServer` has three observable states:

| State | Meaning | `ready?` | `draining?` |
|---|---|---|---|
| `:ready` | Accepting traffic normally | `true` | `false` |
| `:draining` | Rejecting new connections; existing connections finish | `false` | `true` |
| `:stopped` | Server socket closed; no connections | `false` | `false` |

The current status is reflected in every observability snapshot:
```ruby
server.observability_snapshot[:status]  # => :ready | :draining | :stopped
```

### Starting

```ruby
server = LedgerServer.new(address: "127.0.0.1:7400", ...)
server.start_async        # background thread
server.wait_until_ready   # blocks until socket is listening
```

### Draining

`drain` transitions the server to `:draining` without closing the socket.  New
connections are rejected immediately (tracked in
`metrics[:rejected_connections_total]`).  Existing connections are allowed to
finish for up to `drain_timeout` seconds.  Returns `self` for chaining.

```ruby
server.drain(timeout: 10)   # soft-stop; wait up to 10s for in-flight requests
server.stop                 # hard-stop; close socket
```

A `server_draining` structured event is pushed to the ring buffer when `drain`
is called.

### Stopping

`stop` closes the server socket, waits up to `drain_timeout` seconds for active
connections, then closes the backend.  Sets status to `:stopped`.

---

## Readiness vs. health

These are intentionally distinct:

| Endpoint | Question | When 200 | When not |
|---|---|---|---|
| `GET /v1/health` | Is the process alive? | Always while server is up | — |
| `GET /v1/ready` | Should traffic route here? | Only when `ready?` is `true` | 503 when draining or stopped |

Health answers "is this process running?".  Readiness answers "should a load
balancer send traffic here right now?".  Use `/v1/ready` for Kubernetes
readiness probes and load-balancer health checks.

---

## Slow operation tracking

`LedgerServer.new` accepts `slow_op_threshold_ms:` (Integer, or nil to disable):

```ruby
server = LedgerServer.new(
  address:              "127.0.0.1:7400",
  slow_op_threshold_ms: 100   # ops > 100ms are "slow"
)
```

When an operation exceeds the threshold:
1. `ServerMetrics#record_slow_op(op:)` is called (increments `slow_ops_total`).
2. A `:slow_op` event is pushed to the recent-events ring with `elapsed_ms` and
   `threshold_ms` fields.

`slow_ops_total` appears in the metrics snapshot:
```ruby
server.observability_snapshot[:metrics][:slow_ops_total]
# => { "write_fact" => 3, "replay" => 1 }
```

The `slow_op_count` alert threshold fires when the total slow op count exceeds
a configured limit:
```ruby
LedgerServer.new(..., metrics_thresholds: { slow_op_count: 50 })
```

---

## Recent events ring buffer

`LedgerServer` maintains a bounded in-memory ring buffer of structured server
events.  The maximum size is configured via `max_recent_events:` (default 100):

```ruby
server = LedgerServer.new(..., max_recent_events: 500)
```

Events are emitted for:
- `server_start` / `server_stop` — server lifecycle
- `server_draining` — drain transition
- `connection_open` / `connection_close` — per-connection lifecycle
- `subscription_open` / `subscription_close` — push subscription lifecycle
- `request` / `request_error` — per-request (debug level)
- `slow_op` — operation exceeded `slow_op_threshold_ms`
- `alert` — alert threshold breached (e.g. `max_connections`)
- `backend_error` — unexpected error in `handle_client`

Each event is a Hash with at least `type:`, `level:`, and `ts:` fields.

```ruby
server.recent_events
# => [
#   { type: :server_start, level: :info, ts: "2026-05-02T...", bind_address: "...", ... },
#   { type: :connection_open, level: :info, ts: "...", connection_id: "a1b2...", ... },
#   ...
# ]
```

The ring is FIFO: when full, the oldest event is evicted.

---

## HTTP endpoints

All endpoints return `Content-Type: application/json`.

| Method | Path | Description |
|---|---|---|
| `GET` | `/v1/health` | Compact health (always 200 while running) |
| `GET` | `/v1/ready` | Readiness probe (200/503) |
| `GET` | `/v1/status` | Full canonical observability snapshot |
| `GET` | `/v1/metrics` | Metrics sub-hash only |
| `GET` | `/v1/events/recent` | Recent events ring buffer |
| `GET` | `/v1/metadata` | Protocol metadata snapshot |
| `POST` | `/v1/dispatch` | WireEnvelope dispatch |

Non-`GET` requests on GET-only endpoints return `405 Method Not Allowed`.

### `/v1/ready`

```json
// 200 — accepting traffic
{ "status": "ready" }

// 503 — draining or stopped
{ "status": "unavailable" }
```

### `/v1/metrics`

Returns the `metrics` sub-hash from `observability_snapshot`.  Keys include:
`requests_total`, `errors_total`, `slow_ops_total`, `facts_written`,
`facts_replayed`, `bytes_in`, `bytes_out`, `active_connections`,
`accepted_connections_total`, `closed_connections_total`,
`rejected_connections_total`, `subscription_count`.

### `/v1/events/recent`

```json
{
  "events": [
    { "type": "server_start", "level": "info", "ts": "2026-05-02T...", ... },
    ...
  ],
  "count": 42
}
```

### Wiring providers in `start_with_adapters`

When using `LedgerServer#start_with_adapters`, all providers are wired
automatically:

```ruby
server.start_with_adapters(http_port: 7300, tcp_port: 7401)
```

For standalone `HTTPAdapter` usage, pass providers explicitly:

```ruby
adapter = HTTPAdapter.new(
  interpreter:      interpreter,
  ready_provider:   -> { server.ready? },
  metrics_provider: -> { server.observability_snapshot[:metrics] },
  events_provider:  -> { server.recent_events }
)
```

---

## Wire error codes

Error responses from the legacy wire protocol include a stable `error_code`
field alongside the human-readable `error` message:

| Code | Meaning |
|---|---|
| `:unknown_op` | The `op` field is not a recognised operation |
| `:internal_error` | Unexpected exception during dispatch |

```json
{ "ok": false, "error_code": "unknown_op", "error": "Unknown op: \"foo\"" }
```

### request_id passthrough

If a wire request includes a `request_id` field, the server echoes it back in
the response.  This allows clients to correlate async responses with their
originating requests:

```json
// request
{ "op": "ping", "request_id": "req-7f3a" }

// response
{ "ok": true, "pong": true, "request_id": "req-7f3a" }
```

---

## What is intentionally NOT included

- **Auth/TLS** — no authentication or transport encryption.
- **External metrics exporters** — no Prometheus or OpenTelemetry integration.
- **Persistent event log** — the ring buffer is in-memory only; events are lost
  on restart.  Use `ServerLogger` IO output for durable event logging.
- **Cluster management** — no replication, leader election, or distributed
  coordination.
- **fsync durability** — see `docs/storage-durability-contract.md`.
