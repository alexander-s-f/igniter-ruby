# Track: Durable Model Namespace Adoption v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-companion`
Future package name: `packages/igniter-durable-model`

## Context

The package currently named `igniter-companion` is no longer conceptually a
Companion app package.

It is the typed application-facing durable model layer over Ledger:

- `Record`
- `History`
- `Store`
- scopes
- receipts
- manifest-generated classes
- remote `LedgerClient` boundary

The identity proposal is now captured in:

- `packages/igniter-companion/docs/proposals/companion-package-identity.md`
- `docs/research/igniter-lang-convergence-report.md`

Decision:

```text
Companion      -> app/product/example name
Durable Model  -> package/model-layer name
Ledger Client  -> protocol/transport
Ledger         -> hot fact engine
```

## Goal

Introduce `Igniter::DurableModel` as the canonical namespace inside the existing
package while keeping `Igniter::Companion` as a compatibility alias.

Desired canonical usage:

```ruby
require "igniter/durable_model"

class Reminder
  include Igniter::DurableModel::Record

  store_name :reminders
  field :title
  field :status, default: :open

  scope :open, filters: { status: :open }
end

store = Igniter::DurableModel::Store.new
store.register(Reminder)
store.write(Reminder, key: "r1", title: "Buy milk", status: :open)
store.scope(Reminder, :open)
```

Compatibility usage must still work:

```ruby
require "igniter/companion"

class Reminder
  include Igniter::Companion::Record
end
```

## Non-Goals

- Do not physically rename `packages/igniter-companion` in this slice.
- Do not rename the gemspec or gem name in this slice.
- Do not remove `Igniter::Companion`.
- Do not remove `require "igniter/companion"`.
- Do not migrate every example app file if it creates churn.
- Do not change Ledger or Ledger Client semantics.
- Do not introduce core `Store[T]` / `History[T]` language syntax.

Physical package/gem rename is a later slice after namespace adoption is green.

## Required Shape

### 1. Canonical namespace files

Add a canonical load path:

```text
lib/igniter/durable_model.rb
lib/igniter/durable_model/record.rb
lib/igniter/durable_model/history.rb
lib/igniter/durable_model/receipts.rb
lib/igniter/durable_model/store.rb
```

Implementation may either:

- move the current implementation under `Igniter::DurableModel` and make
  `Igniter::Companion` aliases, or
- keep implementation files as internal compatibility files and expose
  `Igniter::DurableModel` constants as canonical aliases.

Prefer the cleaner direction if the diff stays readable:

```ruby
module Igniter
  module DurableModel
    module Record
      ...
    end
  end
end

module Igniter
  module Companion
    Record = DurableModel::Record
  end
end
```

### 2. Compatibility namespace

`Igniter::Companion` must continue to expose:

- `Record`
- `History`
- `Store`
- receipts
- `.from_manifest`

Compatibility should be boring and explicit.

Do not use `const_missing` magic unless absolutely necessary.

### 3. `from_manifest`

Canonical API:

```ruby
Igniter::DurableModel.from_manifest(manifest)
Igniter::DurableModel::Record.from_manifest(manifest)
Igniter::DurableModel::History.from_manifest(manifest)
```

Compatibility API:

```ruby
Igniter::Companion.from_manifest(manifest)
```

Both should return classes including the Durable Model modules.

### 4. Docs

Update package docs so `Durable Model` is the primary language:

- `packages/igniter-companion/README.md`
- `packages/igniter-companion/README.ru.md`
- `packages/igniter-companion/docs/README.md`
- current status docs only if the edit can stay compact

Docs should explain:

```text
This package is still physically named igniter-companion during v0 migration.
The canonical namespace is Igniter::DurableModel.
Igniter::Companion remains a compatibility alias.
```

### 5. Tests

Add or update tests proving:

- `require "igniter/durable_model"` works
- `Igniter::DurableModel::Record` works
- `Igniter::DurableModel::History` works
- `Igniter::DurableModel::Store` works for register/write/read/scope/append/replay
- `Igniter::DurableModel.from_manifest` works for store and history manifests
- `Igniter::Companion::*` compatibility still works
- object class/module identity is clear enough for users
- Ledger Client-backed Store still works through the Durable Model namespace

## Suggested Read Set

1. `packages/igniter-companion/docs/proposals/companion-package-identity.md`
2. `docs/research/igniter-lang-convergence-report.md`
3. `packages/igniter-companion/lib/igniter/companion.rb`
4. `packages/igniter-companion/lib/igniter/companion/record.rb`
5. `packages/igniter-companion/lib/igniter/companion/history.rb`
6. `packages/igniter-companion/lib/igniter/companion/store.rb`
7. `packages/igniter-companion/lib/igniter/companion/receipts.rb`
8. `packages/igniter-companion/spec/igniter/companion/store_spec.rb`
9. `packages/igniter-companion/README.md`
10. `packages/igniter-companion/README.ru.md`

Do not read the whole repository. This is a namespace/package-identity slice.

## Acceptance

Done means:

- `require "igniter/durable_model"` works.
- New examples can use `Igniter::DurableModel::*`.
- Existing `Igniter::Companion::*` tests and examples still work.
- `from_manifest` works from both namespaces.
- Ledger Client-backed Store behavior remains green.
- README presents Durable Model as the canonical name.
- Docs clearly say the physical package is temporarily still
  `igniter-companion`.
- No physical package/gem rename has happened yet.

Required tests:

```bash
BUNDLE_GEMFILE=packages/igniter-companion/Gemfile bundle exec rspec packages/igniter-companion/spec
bundle exec rspec packages/igniter-ledger-client/spec
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec
```

Run the full ledger suite only if the touched code path or dependency wiring
could affect protocol behavior; otherwise report that Companion and Ledger
Client suites are sufficient for this namespace slice.

## Final Notes

- Added canonical `Igniter::DurableModel` load paths under
  `lib/igniter/durable_model*`.
- `Igniter::DurableModel::Record`, `History`, `Store`, `WriteReceipt`, and
  `AppendReceipt` are explicit aliases to the existing implementation constants.
- `require "igniter/companion"` also defines the canonical Durable Model
  namespace, so compatibility users do not get a split constant world.
- `Igniter::DurableModel.from_manifest`, `Record.from_manifest`, and
  `History.from_manifest` work; `Igniter::Companion.from_manifest` remains
  compatible.
- Physical package and gem names are unchanged.

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-companion/durable-model-namespace-adoption-v0
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
