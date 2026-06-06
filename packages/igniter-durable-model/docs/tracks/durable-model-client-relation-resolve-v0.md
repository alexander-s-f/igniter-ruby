# Track: Durable Model Client Relation Resolve v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target packages: `packages/igniter-durable-model`, `packages/igniter-ledger-client`, `packages/igniter-ledger`

## Context

Client-backed Durable Model has reached parity for the common Record/History
surface:

- `register`
- `write`
- `read`
- `scope`
- `on_scope`
- `append`
- plain `replay`
- `replay(partition:)`

The next important embedded-vs-client gap is relations.

Embedded Durable Model supports declared relation auto-wire and typed resolve:

```ruby
class BlogPost
  include Igniter::DurableModel::Record
  store_name :blog_posts

  relation :comments_by_post,
    kind: :event_owner,
    to: :blog_comments,
    cardinality: :one_to_many,
    join: { id: :post_id }
end

store.register(BlogPost)
store.register(BlogComment)
store.write(BlogComment, key: "c1", post_id: "p1", body: "Nice")

comments = store.resolve(:comments_by_post, from: "p1")
# => [#<BlogComment ...>]
```

Client-backed Durable Model currently raises for:

- relation auto-wire during `register`
- `register_relation`
- `resolve`
- `_relations`

Ledger already has protocol-level relation descriptors and `resolve`, and
Ledger Client already exposes `client.resolve(relation:, from:, as_of:)`.
This slice should connect those layers without inventing a new relation model.

## Goal

Make client-backed Durable Model support:

- auto-wiring supported one-to-many relations during `register`
- explicit `register_relation`
- typed `resolve(relation_name, from:, as_of:)`
- `_relations` snapshot when available through metadata

Desired remote shape:

```ruby
client = Igniter::LedgerClient.wrap(ledger.protocol)
store = Igniter::DurableModel::Store.new(client: client)

store.register(BlogPost)
store.register(BlogComment)

store.write(BlogComment, key: "c1", post_id: "p1", body: "Nice")
store.write(BlogComment, key: "c2", post_id: "p2", body: "Other")

comments = store.resolve(:comments_by_post, from: "p1")
# => typed BlogComment records
```

## Required Shape

### 1. Client-backed relation auto-wire

Remove the current client-backed `relation auto-wire` hard stop for relation
shapes that Durable Model already auto-wires in embedded mode:

```ruby
kind in [:event_owner, :ownership]
cardinality == :one_to_many
join is present
```

For unsupported relation shapes, preserve existing behavior:

- ignore non-auto-wire shapes if embedded mode ignores them
- or raise only where embedded mode would raise

Do not make client mode stricter than embedded mode.

### 2. Client-backed `register_relation`

For client-backed stores, lower:

```ruby
store.register_relation(:comments_by_post,
  source: BlogComment,
  partition: :post_id,
  target: BlogPost
)
```

to a standard Ledger relation descriptor:

```ruby
client.register_descriptor(
  schema_version: 1,
  kind: :relation,
  name: :comments_by_post,
  from: { store: :blog_posts, key: :id },
  to:   { store: :blog_comments, field: :post_id },
  cardinality: :many
)
```

Guidance:

- match the existing protocol `RelationHandler` shape
- use target store as `from.store`
- use source store + partition field as `to`
- preserve existing embedded semantics
- keep descriptor result handling normalized through Ledger Client result models

If exact `from.key` cannot be inferred, use `:id` for v0 and document it as
informational, because current protocol only requires the descriptor shape and
engine relation registration uses source/partition/target.

### 3. Client-backed typed resolve

Implement:

```ruby
store.resolve(:comments_by_post, from: "p1", as_of: optional_timestamp)
```

for client-backed stores.

Mapping:

- call `client.resolve(relation:, from:, as_of:)`
- use locally registered schema metadata to type returned source values
- preserve embedded return behavior:
  - if source schema class is known, return typed records
  - otherwise return raw hashes
  - return `[]` for empty relation result
  - unknown relation should raise a clear `ArgumentError` if possible

Important: client-backed resolve must not require direct access to
`@inner.schema_graph`.

Maintain a small local relation registry in Durable Model if needed:

```ruby
@relations_by_name[name] = { source:, partition:, target: }
```

This registry should be populated by explicit `register_relation` and
auto-wire during `register`.

### 4. Client-backed `_relations`

If `metadata_snapshot` includes relation metadata, `_relations` can return that
for client-backed mode.

If remote metadata shape is too different, return the local registry snapshot
from Durable Model. Prefer a compact stable shape compatible with embedded
tests:

```ruby
{
  comments_by_post: {
    source: :blog_comments,
    partition: :post_id,
    target: :blog_posts,
    index_store: :__rel_comments_by_post
  }
}
```

Do not expose raw protocol envelopes from `_relations`.

### 5. Ledger Client result shape

If `client.resolve` currently returns raw arrays, decide whether to add a
`ResolveResult` model.

Preferred if low churn:

```ruby
Igniter::LedgerClient::Results::ResolveResult
  #results
  #count
```

Keep backward compatibility if existing callers expect raw arrays. If result
model is too much for this slice, keep raw array and wrap inside Durable Model.

### 6. Docs

Update Durable Model README/current docs:

- client-backed mode now supports declared one-to-many relation auto-wire and
  typed `resolve`
- relation/projection/scatter direct snapshots or registration remain gaps only
  if still unsupported
- clarify that relation support is v0 and uses Ledger relation descriptors

## Non-Goals

- No many-to-one/reference relation implementation if embedded mode does not
  auto-wire it.
- No remote projection/scatter registration in this slice.
- No relation subscriptions.
- No remote relation query language.
- No cross-store transaction semantics.
- No new relation protocol operation if existing descriptor + resolve is enough.
- No deletion/tombstone relation consistency changes.

## Suggested Read Set

1. `packages/igniter-durable-model/lib/igniter/durable_model/store.rb`
2. `packages/igniter-durable-model/lib/igniter/durable_model/record.rb`
3. `packages/igniter-durable-model/spec/igniter/companion/store_spec.rb`
4. `packages/igniter-durable-model/spec/igniter/durable_model_spec.rb`
5. `packages/igniter-ledger-client/lib/igniter/ledger_client/client.rb`
6. `packages/igniter-ledger-client/lib/igniter/ledger_client/results.rb`
7. `packages/igniter-ledger-client/spec/igniter/ledger_client/client_spec.rb`
8. `packages/igniter-ledger/lib/igniter/store/protocol/handlers/relation_handler.rb`
9. `packages/igniter-ledger/lib/igniter/store/protocol/interpreter.rb`
10. `packages/igniter-ledger/lib/igniter/store/protocol/wire_envelope.rb`
11. `packages/igniter-ledger/spec/igniter/store/protocol/op1_spec.rb`
12. `packages/igniter-ledger/spec/igniter/store/protocol/op3_spec.rb`

Do not read the whole repository. This is a relation descriptor / client-backed
Durable Model parity slice.

## Acceptance

Done means:

- Client-backed Durable Model no longer rejects supported relation auto-wire.
- Client-backed `register_relation` lowers to Ledger relation descriptor.
- Client-backed `resolve` works for registered one-to-many relations.
- Client-backed `resolve(..., as_of:)` works if Ledger protocol already supports
  it.
- Client-backed resolve returns typed records when source schema class is known.
- Client-backed resolve returns `[]` when no relation entries exist.
- Unknown relation fails clearly.
- Embedded relation behavior is unchanged.
- `_relations` works in client-backed mode via local registry or metadata
  snapshot.
- Docs list relation resolve as supported for client-backed mode.
- Remaining unsupported client-backed features still fail clearly.

Required tests:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec
```

If full Ledger suite is too expensive for the current turn, at minimum run the
Ledger protocol specs touched by relation descriptor and resolve.

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-durable-model/client-relation-resolve-v0
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

- Client-backed Durable Model now auto-wires supported one-to-many relations and
  lowers explicit `register_relation` calls to Ledger relation descriptors.
- Client-backed `resolve(relation_name, from:, as_of:)` now returns typed source
  records when the source schema is registered, and `[]` for empty relation
  partitions.
- Ledger Client now wraps resolve responses in `ResolveResult` with
  `items`/`results`/`count`; protocol wire resolve preserves value-only
  `results` while adding keyed `items`.
