# Package Agent Onboarding

Status date: 2026-05-03
Status: active compact entrypoint
Owner: [Architect Supervisor / Codex]
Audience: Package Agent / Companion+Store

## Purpose

Use this file as the first read for a fresh Package Agent chat. The goal is to
avoid reloading the whole repository after every large completed slice.

Package Agent should read this file, then exactly one assigned `docs/tracks/*`
document, then inspect only the files needed for that track.

## Package Shape

```text
packages/igniter-ledger
  lib/igniter/store/
    fact.rb                     canonical Fact model
    igniter_store.rb            embedded store facade and derivation hooks
    file_backend.rb             CRC32 WAL backend
    segmented_file_backend.rb   segmented WAL backend
    codecs.rb                   json_crc32 and compact_delta_zlib codecs
    protocol/                   Ledger Open Protocol interpreter + handlers
    store_server.rb             TCP server and adapter startup surface
    *_adapter.rb                HTTP/MCP/wire adapters

  ext/igniter_store_native/
    src/                        Rust native acceleration path

  examples/intelligent_ledger/
    availability proof; product-pressure example, not core API

  docs/
    README.md                   docs index
    progress.md                 compact current status
    docs-workflow.md            docs lifecycle
    tracks/                     executable Package Agent slices
    proposals/                  decision candidates, not implementation orders
    research/                   exploratory history, read only when assigned
```

## Current Model

`igniter-ledger` is a Ledger substrate:

```text
Fact
  -> append-only log
  -> current read / time-travel read
  -> access paths / relations / projections / derivations
  -> protocol / wire / HTTP / MCP surfaces
```

Canonical `Fact` fields:

```text
id, store, key, value, value_hash, causation,
transaction_time, valid_time, schema_version,
producer, derivation
```

Compatibility aliases exist during pre-v1 migration:

```text
timestamp -> transaction_time
term      -> valid_time
```

## Working Rules

- Treat `docs/tracks/*` as implementation authority.
- Treat `docs/proposals/*` as design candidates until promoted into a track.
- Treat `docs/research/*` and long historical logs as optional source material,
  not as required onboarding.
- Prefer one large vertical slice per Package Agent chat.
- After a large slice lands, close that chat and start a fresh one with this
  onboarding file plus the next track.
- Keep handoff compact:

```text
[Package Agent / Companion+Store]
Track: ...
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

## Default Read Set

For a new implementation slice, read in this order:

1. `docs/package-agent-onboarding.md`
2. `docs/progress.md`
3. the assigned `docs/tracks/<track>.md`
4. only the source/spec files named or implied by that track

Do not read the full repository unless the assigned track explicitly requires a
cross-package audit.
