# Track: Companion Ledger Client Remote Boundary v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-companion`

## Context

`igniter-ledger-client` now owns the standard client/protocol boundary:

- first-class `append`
- normalized result objects
- local object dispatch
- remote HTTP dispatch

`Igniter::Companion::Store` still supports remote Ledger through the older
`Igniter::Store::NetworkBackend` path:

```ruby
Igniter::Companion::Store.new(
  backend: :network,
  address: "127.0.0.1:7400",
  transport: :tcp
)
```

That path is valid legacy/internal transport proof, but it should not keep
growing as the ecosystem-facing boundary. Companion should be able to accept a
standard `LedgerClient`.

## Goal

Add a `client:` construction path to `Igniter::Companion::Store`:

```ruby
client = Igniter::LedgerClient.remote_http("http://127.0.0.1:7300/v1/dispatch")
store = Igniter::Companion::Store.new(client: client)
```

The existing local embedded paths must remain unchanged:

```ruby
Igniter::Companion::Store.new
Igniter::Companion::Store.new(backend: :memory)
Igniter::Companion::Store.new(backend: :file, path: "...")
```

The old `backend: :network` path should remain compatible for now, but new docs
should present `client:` as the preferred remote boundary.

## Non-Goals

- Do not remove `NetworkBackend`.
- Do not force local embedded Companion stores through `LedgerClient`.
- Do not make Companion depend on Ledger server availability for local tests.
- Do not add pooling/retry/outbox behavior in this slice.
- Do not rename `Igniter::Store` internals.
- Do not change `Record` / `History` public ergonomics.
- Do not implement relation resolution over client if it requires new protocol
  operations; document remaining gaps instead.

## Suggested Read Set

1. `packages/igniter-ledger-client/docs/proposals/ledger-client-adoption-map.md`
2. `packages/igniter-ledger-client/docs/tracks/ledger-client-result-models-v0.md`
3. `packages/igniter-companion/lib/igniter/companion/store.rb`
4. `packages/igniter-companion/spec/igniter/companion/store_spec.rb`
5. `packages/igniter-companion/README.md`
6. `packages/igniter-companion/README.ru.md`
7. `packages/igniter-companion/Gemfile`
8. `packages/igniter-companion/igniter-companion.gemspec`

Only inspect `igniter-ledger` internals if a Companion method cannot be mapped
through the current client result objects.

## Implementation Guidance

### 1. Dependency

Add `igniter-ledger-client` as a package dependency for Companion.

Keep `igniter-ledger` dependency because local embedded stores still use the
engine.

### 2. Construction

Add `client: nil` to `Igniter::Companion::Store#initialize`.

Expected behavior:

- if `client:` is given, use it as the Ledger boundary
- if `client:` is given together with `backend:` options, raise a clear
  `ArgumentError` or define explicit precedence; prefer raising to avoid
  surprising mixed modes
- if no `client:` is given, keep existing backend behavior

### 3. Internal Adapter Shape

Companion currently expects `@inner` to expose embedded engine methods:

- `register_descriptor`
- `write`
- `read`
- `query`
- `append`
- `history`
- `history_partition`
- `register_path`
- `register_relation`
- `schema_graph`
- `protocol`

Do not fake the entire engine if it becomes too broad.

Instead, create a small private adapter for client-backed mode that supports
the minimum proven Companion methods:

- `register_descriptor`
- `write`
- `read`
- `append`
- `history` via `client.replay`

Then make `Igniter::Companion::Store` methods branch through focused helper
methods where needed.

Recommended v0 support:

- `register`
- `write`
- `read`
- `append`
- `replay` without partition
- `metadata_snapshot`
- `descriptor_snapshot`

Allowed v0 gaps:

- `scope`
- `on_scope`
- relation auto-wire / `resolve`
- partition-index optimized replay

For unsupported client-backed methods, raise a clear `NotImplementedError` with
the missing protocol capability.

### 4. Result Normalization

Use client result objects:

- `WriteResult#fact_id`, `#value_hash`, `#key`
- `AppendResult#fact_id`, `#value_hash`, `#key`
- `ReadResult#value`, `#found?`
- `ReplayResult#facts`

Do not reach into raw protocol hashes from Companion.

### 5. Docs

Update Companion docs to show:

```ruby
client = Igniter::LedgerClient.remote_http("http://127.0.0.1:7300/v1/dispatch")
store = Igniter::Companion::Store.new(client: client)
```

Also document v0 unsupported methods for client-backed mode.

## Acceptance

Done means:

- Companion depends on `igniter-ledger-client`
- `Igniter::Companion::Store.new(client: client)` works
- client-backed Companion can register a simple Record and History descriptor
- client-backed Companion can `write` and `read` a Record
- client-backed Companion can `append` and `replay` a History without partition
- local embedded Companion store specs still pass
- old `backend: :network` behavior is not removed
- unsupported client-backed methods fail clearly
- no new dependency from `igniter-ledger-client` to `igniter-ledger`

Required tests:

```bash
BUNDLE_GEMFILE=packages/igniter-companion/Gemfile bundle exec rspec packages/igniter-companion/spec
bundle exec rspec packages/igniter-ledger-client/spec
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec
```

If full ledger specs require local sockets, run them outside sandbox.

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-companion/companion-ledger-client-remote-boundary-v0
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

## Final Notes

Status date: 2026-05-04.

- Added `igniter-ledger-client` as a Companion dependency.
- Added `Igniter::Companion::Store.new(client: client)`.
- Added a private client-backed adapter supporting descriptor registration,
  write/read, append/plain replay, metadata snapshots, descriptor snapshots, and
  close.
- Client-backed Companion uses `WriteResult`, `AppendResult`, `ReadResult`, and
  `ReplayResult` instead of raw protocol hashes.
- Local embedded `backend: :memory` / `:file` and legacy `backend: :network`
  construction remain in place.
- Initial client-backed v0 raised `NotImplementedError` for scope queries,
  scope subscriptions, relation/scatter/projection operations, causation
  chains, key-filtered history, and partition replay. Scope queries are promoted
  in `companion-ledger-client-scope-query-boundary-v0`; the other gaps remain
  explicit.
- No dependency from `igniter-ledger-client` to `igniter-ledger` was introduced.
