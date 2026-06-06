# Igniter Ledger Server API Proposal

Status date: 2026-05-02.
Status: shipped (HTTPAdapter + TCPAdapter + LedgerServer wiring, 2026-05-02).
Not a stable public API.

## Claim

Igniter Ledger Open Protocol is the semantic waist. The server API should expose
that waist over transport without inventing a second meaning layer.

```text
clients
  CompanionStore / MCP adapter / agents / external DSLs / JS apps / sync hubs
        |
        v
Server API layer
  HTTP / TCP / Unix socket / SSE or WebSocket
        |
        v
WireEnvelope
  protocol, schema_version, request_id, op, packet
        |
        v
Protocol::Interpreter
  descriptor import, fact IO, query, resolve, metadata, replay, sync
        |
        v
IgniterStore fact engine
```

The server should be a protocol host and durable projection host. It must not
become a contract-logic RPC server.

MCP should sit above this layer as an agent-facing adapter. Its remote mode
should call `/v1/dispatch`, not invent a second network protocol.

## Layers

### 1. Protocol Core

Already shipped in `Igniter::Store::Protocol::Interpreter`:

- `register_descriptor`
- `write` / `write_fact`
- `read` / `query` / `resolve`
- `metadata_snapshot` / `descriptor_snapshot`
- `replay` / `sync_hub_profile`

This layer is in-process Ruby and owns all protocol semantics.

### 2. Wire Envelope

Already shipped in `Igniter::Store::Protocol::WireEnvelope`:

```ruby
{
  protocol: :igniter_store,
  schema_version: 1,
  request_id: "req_123",
  op: :write_fact,
  packet: {
    kind: :fact,
    store: :tasks,
    key: "t1",
    value: { title: "Draft API" }
  }
}
```

Response:

```ruby
{
  protocol: :igniter_store,
  schema_version: 1,
  request_id: "req_123",
  status: :ok,
  result: { ... }
}
```

Errors remain envelope-shaped:

```ruby
{
  protocol: :igniter_store,
  schema_version: 1,
  request_id: "req_123",
  status: :error,
  error: "Unknown or missing op: :teleport"
}
```

### 3. Transport Adapters

Two independent adapter classes, both delegating to a shared
`Protocol::Interpreter`. Both live in the same `LedgerServer` process.

#### HTTPAdapter

```ruby
adapter = Igniter::Store::HTTPAdapter.new(interpreter: interpreter, port: 7300)
adapter.rack_app   # → Rack-compatible callable, mountable in any server
adapter.start      # → starts WEBrick (dev/test) or Puma (via dev dep)
```

HTTP stack: Rack interface. No HTTP production dependency.
`rack` and `puma` are development dependencies only — the user mounts `rack_app`
in their own server in production.

Routes:

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/v1/dispatch` | Canonical: accepts/returns one WireEnvelope |
| `GET`  | `/v1/health`   | Liveness + protocol version |
| `GET`  | `/v1/metadata` | Convenience → `metadata_snapshot` |

All other operations go through `/v1/dispatch`. Convenience routes that cannot
be expressed as wire ops must not be added.

Testing: `rack-test` (dev dep) — `rack_app.call(env)`, no network sockets.

#### TCPAdapter

```ruby
adapter = Igniter::Store::TCPAdapter.new(interpreter: interpreter, port: 7401)
adapter.start  # framed WireProtocol read → wire.dispatch → framed response
```

Uses existing `WireProtocol` CRC32 framing. Reads one envelope hash per frame,
dispatches, writes one response frame.

Port 7401 is distinct from the legacy LedgerServer port (7400). `LedgerNetworkBackend`
continues to talk to the legacy path — TCPAdapter is the new envelope path.

### 4. LedgerServer Process Model

All transports in one process. `LedgerServer` owns `IgniterStore` and
`Protocol::Interpreter`. Adapters receive the interpreter as a dependency.

```text
LedgerServer process
  IgniterStore  (durable facts)
  Protocol::Interpreter  (OP1–OP5 semantics)

  Legacy path (port 7400):     write_fact / replay / subscribe
  HTTPAdapter  (port 7300):    /v1/dispatch  →  interpreter.wire.dispatch
  TCPAdapter   (port 7401):    framed packet →  interpreter.wire.dispatch
```

CLI: `igniter-ledger-server --http-port 7300 --tcp-port 7401`

Subscriptions (SSE or framed push): out of scope for first slice. The legacy
`subscribe` path on port 7400 remains available.

## Minimal HTTP Surface

The canonical surface should be small:

| Route | Purpose |
|-------|---------|
| `POST /v1/dispatch` | Canonical protocol operation endpoint. |
| `GET /v1/health` | Server liveness/readiness and protocol version. |
| `GET /v1/metadata` | Convenience wrapper for `metadata_snapshot`. |
| `POST /v1/sync/profile` | Convenience wrapper for `sync_hub_profile`. |
| `GET /v1/events` | SSE stream for fact/subscription events. |

Only `/v1/dispatch` is required for the first slice. The rest are convenience
or operational endpoints.

## Convenience Endpoints

Convenience REST endpoints may be useful later, but they should lower to
wire-envelope operations internally:

| Route | Lowers to |
|-------|-----------|
| `POST /v1/descriptors` | `op: :register_descriptor` |
| `POST /v1/facts` | `op: :write_fact` |
| `GET /v1/stores/:store/:key` | `op: :read` |
| `POST /v1/query` | `op: :query` |
| `POST /v1/resolve` | `op: :resolve` |
| `GET /v1/replay` | `op: :replay` |

These are adapters, not separate semantics. If a convenience endpoint cannot be
expressed as a wire op, it should not be added yet.

## MCP Adapter Relationship

MCP is a client adapter for operators and agents:

```text
MCP tool/resource
  -> local Protocol::Interpreter#dispatch
  or remote POST /v1/dispatch
  -> Ledger Open Protocol result
```

The MCP layer may rename operations into tool-friendly names, add bounded
resource views, and apply tool policy. It must not add persistence semantics.
Mutating MCP tools should be disabled by default until policy and receipt
handling are explicit.

## LedgerServer Integration

Current `LedgerServer` already hosts durable facts and network replay/write
paths. The new adapter layer adds envelope dispatch without touching the
existing lower-level path.

```text
LedgerServer
  owns: IgniterStore
  owns: Protocol::Interpreter  ← new ownership, lazy-initialised
  owns: HTTPAdapter            ← new, wraps interpreter
  owns: TCPAdapter             ← new, wraps interpreter
  legacy:
    write_fact / replay / subscribe paths (port 7400, unchanged)
```

Existing `LedgerNetworkBackend` tests remain valid — legacy port is untouched.

## Boundary Rules

- No contract node execution in the server.
- No Ruby DSL evaluation in the server.
- No materializer execution in the server.
- No SQL/ORM assumptions in protocol routes.
- No hidden migration or schema enforcement from descriptor registration.
- No public API stability promise before conformance tests exist.

The server may store descriptors, facts, receipts, snapshots, subscriptions,
and sync profiles. It may not decide business meaning.

## Security And Policy

Not first-slice requirements, but the API shape should leave room for:

- API token or mTLS authentication.
- Per-client producer metadata.
- Operation allowlists.
- Store-level read/write authorization.
- Rate limits for write/query/replay.
- Audit facts for accepted/rejected remote operations.

Security policy should wrap the dispatch layer, not fork protocol semantics.

## Observability

Minimum operational status:

```text
GET /v1/health
  -> protocol=:igniter_store
  -> schema_version=1
  -> status=:ready | :draining | :error
  -> backend=:memory | :file
  -> fact_count
  -> subscription_count
```

Future diagnostics can expose:

- protocol op counts
- rejection counts
- replay cursor
- compaction receipt count
- last checkpoint time
- active subscribers

## First Slice

Recommended slice: LedgerServer envelope integration.

Aim:

```text
HTTP or framed request
  -> WireEnvelope#dispatch
  -> Protocol::Interpreter
  -> IgniterStore
  -> envelope response
```

Acceptance:

- `POST /v1/dispatch` accepts an OP3 envelope.
- `register_descriptor -> write -> read -> query -> resolve -> metadata_snapshot`
  works through the server boundary.
- `sync_hub_profile` works through the same boundary.
- Error responses remain envelope-shaped.
- Existing `write_fact`, `replay`, and `subscribe` server behavior still passes.
- Server does not evaluate contract logic.

Suggested smoke:

```text
1. register store descriptor :tasks
2. register relation descriptor :project_tasks
3. write task facts
4. read one task
5. query open tasks
6. resolve project_tasks
7. fetch metadata_snapshot
8. fetch sync_hub_profile
```

## Resolved Decisions

| Question | Decision |
|----------|----------|
| First transport | Both HTTP and TCP/Unix from day one |
| HTTP stack | Rack interface + Puma/WEBrick as dev deps only |
| Two transports config | Two independent adapter classes (HTTPAdapter, TCPAdapter) |
| Process model | All in one LedgerServer process, two ports |
| LedgerNetworkBackend migration | Legacy path stays; envelope path is additive |
| Subscriptions (first slice) | Out of scope — legacy subscribe path remains |

## Open Questions (remaining)

- Should descriptor registration persist across server restart before the
  protocol API is called stable? (Suggestion: file WAL already handles this
  if `backend: :file` is used — descriptors are not currently in the WAL, so
  re-registration on startup may be required until WAL includes descriptors.)
- Should sync profiles be generated on demand only, or also persisted as facts?

## First Slice Acceptance

```text
1. LedgerServer starts HTTPAdapter (port 7300) and TCPAdapter (port 7401)
2. POST /v1/dispatch accepts OP3 envelope → WireEnvelope#dispatch → response
3. register_descriptor → write → read → query → resolve → metadata_snapshot
   all work through both transports
4. sync_hub_profile works through both transports
5. Error responses remain envelope-shaped
6. Legacy write_fact / replay / subscribe on port 7400 still passes all specs
7. CLI accepts --http-port and --tcp-port flags
```

Suggested smoke sequence:
```text
1. register store descriptor :tasks
2. register relation descriptor :project_tasks
3. write task facts
4. read one task
5. query open tasks
6. resolve project_tasks
7. fetch metadata_snapshot
8. fetch sync_hub_profile
```

## Handoff

```text
[Architect Supervisor / Codex]
Track: igniter-ledger-server-api
Status: shipped (2026-05-02). All first-slice acceptance criteria met.
[D] Open Protocol is the semantic waist; server API is transport over it.
[D] Both HTTP (Rack, port 7300) and TCP (port 7401) adapters ship together.
[D] HTTPAdapter exposes rack_app + Rack::Builder routes; rack ~> 3.0 is prod dep.
[D] TCPAdapter reuses WireProtocol CRC32 framing.
[D] All transports in one LedgerServer process; legacy port 7400 untouched.
[D] LedgerNetworkBackend legacy path stays until envelope compatibility is proven.
[D] Subscriptions are out of scope for this slice.
[D] SyncProfile#to_json serializes as hash over wire (Struct default is array).
[R] Convenience REST endpoints must lower to protocol ops and add no semantics.
[R] LedgerServer remains fact/projection host, not contract-logic RPC.
Next: architect-selected — descriptor WAL persistence, SSE push, or conformance tests.
```
