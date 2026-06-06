# Igniter Ledger MCP Adapter Proposal

Status date: 2026-05-02.
Status: proposal. Not a stable public API.

## Claim

Igniter Ledger does need an MCP surface, but MCP should be an agent adapter over
Ledger Open Protocol, not a new persistence model.

```text
Codex / Research / package agents / local operator tools
        |
        v
igniter-ledger MCP adapter
  resources + tools + policy
        |
        v
local Protocol::Interpreter
or remote Store Server /v1/dispatch
        |
        v
Igniter Ledger Open Protocol
  descriptors / facts / receipts / query / resolve / replay / sync
        |
        v
IgniterStore backends
```

The MCP adapter is useful because agents should be able to inspect store shape,
query facts, resolve relations, fetch sync profiles, and produce bounded
diagnostics without learning Ruby internals or bypassing the protocol waist.

## Boundary Rules

- MCP tools must lower to Ledger Open Protocol operations or named protocol
  metadata views.
- MCP must not execute Igniter contracts.
- MCP must not evaluate Ruby DSL.
- MCP must not materialize dynamic contracts by itself.
- MCP must not bypass `Protocol::Interpreter` or `/v1/dispatch`.
- Mutating tools are disabled by default until policy and receipt semantics are
  explicit.
- Tool outputs should include `schema_version`, `request_id`, and
  `source_protocol_op` whenever the tool maps to an operation.

MCP is an operator and agent access layer. The semantic source of truth remains
Open Protocol.

## Transport Modes

### Local Embedded Mode

The MCP server is started next to a local store instance:

```text
MCP tool call
  -> Igniter::Store::Protocol::Interpreter#dispatch
  -> local IgniterStore backend
```

Use this for tests, local development, app-embedded stores, and agent sidecars.

### Remote Store Server Mode

The MCP server talks to a running LedgerServer:

```text
MCP tool call
  -> POST /v1/dispatch
  -> LedgerServer HTTPAdapter
  -> Protocol::Interpreter
```

Use this for shared stores, cluster stores, and remote operator workflows.

Both modes must return the same logical payloads for the same protocol request.

## Resources

MCP resources are read surfaces. They should be cheap, bounded, and safe to
list.

| Resource | Meaning |
|----------|---------|
| `igniter-ledger://metadata` | Unified metadata snapshot |
| `igniter-ledger://descriptors` | Registered descriptors grouped by kind |
| `igniter-ledger://stores` | Store names, capabilities, and field summaries |
| `igniter-ledger://relations` | Relation descriptors and readiness |
| `igniter-ledger://sync-profile` | Current sync profile summary |
| `igniter-ledger://segments` | Segment and partition manifest summary |
| `igniter-ledger://conformance` | Adapter/protocol compatibility report |

Large payload resources should support cursors or filters before they become
public.

## Read-Only Tools

These are the first safe tool family.

| Tool | Lowers to | Purpose |
|------|-----------|---------|
| `metadata_snapshot` | `op: :metadata_snapshot` | Inspect protocol registry |
| `descriptor_snapshot` | protocol metadata view | Inspect descriptors only |
| `read` | `op: :read` | Read one current or `as_of` value |
| `query` | `op: :query` | Query a bounded store view |
| `resolve` | `op: :resolve` | Resolve a registered relation |
| `replay` | `op: :replay` | Replay bounded facts |
| `sync_profile` | `op: :sync_hub_profile` | Inspect sync cursor/profile |
| `storage_stats` | backend metadata view | Inspect byte/fact/segment counts |
| `segment_manifest` | backend metadata view | Inspect partitions and codecs |

Read tools must enforce limits. A tool that can stream or replay unbounded facts
must require an explicit `limit`, cursor, time range, or store filter.

Example tool call:

```json
{
  "tool": "query",
  "arguments": {
    "store": "sensor_readings",
    "where": { "sensor_id": "s1" },
    "limit": 100,
    "as_of": null
  }
}
```

Example tool response:

```json
{
  "schema_version": 1,
  "request_id": "mcp_req_001",
  "source_protocol_op": "query",
  "status": "ok",
  "result": []
}
```

## Gated Write Tools

Mutating tools are second-slice only. They should remain unavailable unless an
explicit policy enables them.

| Tool | Lowers to | Gate |
|------|-----------|------|
| `register_descriptor` | `op: :register_descriptor` | descriptor write policy |
| `write_fact` | `op: :write` or `op: :write_fact` | fact write policy |
| `append_history` | `op: :append` | history write policy |
| `compact` | `op: :compact` | destructive lifecycle policy |
| `checkpoint` | backend lifecycle op | lifecycle policy |

Every mutating tool must return a receipt-shaped result. Destructive lifecycle
tools must support `dry_run: true` and should require explicit confirmation or a
configured policy token.

Example write response:

```json
{
  "schema_version": 1,
  "request_id": "mcp_req_042",
  "source_protocol_op": "write",
  "status": "ok",
  "receipt": {
    "kind": "receipt",
    "status": "accepted",
    "store": "sensor_readings",
    "key": "sensor-1:2026-05-02T10:30:00Z"
  }
}
```

## Safety Classes

MCP tools should be grouped by policy class:

| Class | Examples | Default |
|-------|----------|---------|
| `read` | metadata, read, query, resolve, sync_profile | enabled |
| `bounded_stream` | replay, segment_manifest | enabled with limits |
| `descriptor_write` | register_descriptor | disabled |
| `fact_write` | write_fact, append_history | disabled |
| `lifecycle` | compact, checkpoint | disabled |

This gives agents a clear capability model and makes later MCP authorization
compatible with LedgerServer authorization.

## Agent Workflows

The first valuable workflows are inspection and diagnosis:

```text
agent asks: "What stores exist?"
  -> metadata_snapshot
  -> descriptors/resources summary

agent asks: "Why is relation X empty?"
  -> relation descriptor
  -> query source store
  -> resolve relation
  -> produce diagnosis

agent asks: "Can this cluster sensor store sync?"
  -> sync_profile
  -> segment_manifest
  -> storage_stats
  -> produce readiness report
```

MCP should make these workflows reliable without giving the agent raw file
system write access or Ruby code execution.

## Relationship To Server API

The MCP adapter has two legal implementation paths:

```text
embedded:
  tool -> Protocol::Interpreter#dispatch

remote:
  tool -> HTTP POST /v1/dispatch -> Protocol::Interpreter#dispatch
```

The remote path should not call convenience REST endpoints unless they are
strict wrappers over the same wire envelope. `/v1/dispatch` is the canonical
remote boundary.

## First Slice Acceptance

Recommended first slice: read-only MCP adapter.

Acceptance:

- MCP server exposes read-only tools for `metadata_snapshot`, `read`, `query`,
  `resolve`, `replay`, and `sync_profile`.
- Every tool maps to a protocol op or named metadata view.
- Every operation returns `schema_version`, `request_id`, `status`, and
  `source_protocol_op` where applicable.
- Replay and query require a bounded limit or cursor.
- No mutating tool is enabled by default.
- Embedded mode works against an in-memory store.
- Remote mode works through LedgerServer `/v1/dispatch`.
- A small conformance smoke proves embedded and remote modes return equivalent
  logical results.

Suggested smoke:

```text
1. start store with a tasks descriptor
2. write facts outside MCP through Protocol::Interpreter
3. MCP metadata_snapshot sees the descriptor
4. MCP query sees bounded tasks
5. MCP resolve sees a registered relation
6. MCP sync_profile returns a profile
7. repeat through remote LedgerServer /v1/dispatch
```

## Open Questions

- Should the MCP adapter live in `packages/igniter-ledger`, a future
  `packages/igniter-mcp-adapter`, or both with a thin package wrapper?
- Should write tools use one policy file shared with LedgerServer?
- Should segment manifests be exposed as protocol descriptors before MCP uses
  them?
- Should MCP resources expose raw JSON only, or also compact markdown summaries
  for human operator tools?

## Handoff

```text
[Architect Supervisor / Codex]
Track: igniter-ledger-mcp-adapter
Status: proposal, read-only first.
[D] MCP is an agent adapter over Ledger Open Protocol, not a second Store API.
[D] Legal paths: embedded Protocol::Interpreter or remote /v1/dispatch.
[D] Read-only inspection comes first; mutating tools are gated and receipt-based.
[R] No contract execution, Ruby DSL eval, materializer execution, or protocol bypass.
[R] Query/replay must be bounded by limit, cursor, store, or time range.
[R] Tool responses should preserve schema_version/request_id/source_protocol_op.
Next: implement read-only MCP adapter after or alongside LedgerServer dispatch conformance.
```
