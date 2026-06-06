# igniter-ledger Architect Supervisor Backlog

Status date: 2026-05-02
Owner: [Architect Supervisor / Codex]
Status: small local backlog, not Package Agent task pack

## Purpose

Track small polish, hardening, and follow-up items that should stay in the
Architect Supervisor/Codex loop. Package Agent should keep working on large
vertical slices.

If one of these items becomes a larger architectural slice, promote it into a
separate proposal or task-pack document.

## Current Rule

```text
Package Agent
  large vertical slices, broad context, package-level implementation

Architect Supervisor / Codex
  local fixes, small validation, doc tightening, conformance glue
```

## Backlog

### Flush Policy Validation

Add fail-fast validation for `SegmentedFileBackend.new(flush:)`.

Acceptance:

- `:batch` and `:on_write` are accepted.
- `{ every_n: N }` requires `N` to be a positive integer.
- Unknown policies raise `ArgumentError`.
- Specs cover invalid symbol, missing `every_n`, zero, negative, and non-integer.

### Durability Snapshot Surface Glue

If Package Agent's Store Server Production Surface slice does not cover it,
surface `durability_snapshot` through observability/status.

Acceptance:

- `/v1/status` can include durability state when the backend supports it.
- Buffered compact-delta facts can trigger an alert dimension.
- No runtime storage implementation details leak beyond the documented snapshot.

### Degraded Storage Stats

`Protocol::Interpreter#observability_snapshot` currently treats
`storage_stats` failure as `storage: nil` and still reports `status: :ready`.
Tighten this.

Acceptance:

- storage stats failure yields `status: :degraded`.
- alert includes `type: :storage_stats_unavailable`.
- tests prove failures are visible rather than silently hidden.

### Status Path Storage Stats Cache

Avoid making `storage_stats` an expensive hot path under frequent `/v1/status`
or MCP observability calls.

Acceptance:

- short TTL cache or manifest-backed stats path exists.
- tests prove cache expiry/refresh behavior if TTL is introduced.
- no stale cache is used for explicit storage diagnostics where freshness is
  requested.

### Legacy `server_status` Shape Cleanup

The legacy `"server_status"` command currently prepends `ok: true` to the
canonical observability snapshot. Keep compatibility, but document or normalize
the shape.

Acceptance:

- clean canonical path remains `/v1/status` and MCP `observability_snapshot`.
- legacy path is documented as compatibility.
- no new clients are encouraged to depend on `ok: true` mixed into canonical
  status fields.

### Storage Durability Spec Tempdir Cleanup

Review `storage_durability_spec` for temporary directories created inside tests
that are not covered by the example's `after` cleanup.

Acceptance:

- every `Dir.mktmpdir` has a matching cleanup path.
- specs stay green.

### Benchmark Policy Dimension

Extend storage benchmark output to record durability policy alongside codec.

Acceptance:

- benchmark rows include `codec`, `flush_policy`, bytes/fact, write throughput,
  replay throughput, and loss-window note.
- compact-delta `:batch`, `:on_write`, and `every_n` can be compared honestly.

### `compact_delta` Ratio Note

Document that `:on_write` changes the effective compression ratio because each
fact may become a tiny batch frame.

Acceptance:

- docs avoid implying `:on_write` has the same bytes/fact profile as default
  `:batch`.
- benchmark plan captures the actual ratio.

### Closed/Inactive Store Durability Snapshot

Decide whether `durability_snapshot` should only report live active segments or
also include sealed/inactive stores from manifests.

Acceptance:

- current behavior is documented.
- if expanded, snapshot distinguishes `active`, `sealed`, and `closed` stores.

## Parking Lot

These are real but not "small":

- `fsync` policy and physical power-loss durability.
- Rust segmented storage implementation.
- durable Changefeed cursor/checkpoint replay.
- Store-to-Ledger naming migration.
