# Track: Durable Model Package Rename v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Current package: `packages/igniter-companion`
Target package: `packages/igniter-durable-model`

## Context

`Igniter::DurableModel` is now the canonical Ruby namespace while the physical
package is still named `igniter-companion`.

Done before this slice:

- `require "igniter/durable_model"` works.
- `Igniter::DurableModel::Record`, `History`, `Store`, `WriteReceipt`, and
  `AppendReceipt` exist.
- `Igniter::Companion::*` remains a compatibility alias.
- package docs now present Durable Model as the canonical namespace.
- tests prove local Store and LedgerClient-backed Store usage.

The next step is to align package identity with namespace identity.

## Goal

Physically rename the package directory and gem identity to Durable Model while
preserving a compatibility path for `igniter-companion`.

Target:

```text
packages/igniter-durable-model
  README.md
  README.ru.md
  Gemfile
  Rakefile
  igniter-durable-model.gemspec
  lib/igniter/durable_model.rb
  lib/igniter/durable_model/*
  lib/igniter/companion.rb                  # compatibility shim
  lib/igniter/companion/*                   # compatibility shims if needed
  spec/igniter/durable_model_spec.rb
  spec/igniter/companion_compat_spec.rb
```

Old require paths should continue to work from the new package:

```ruby
require "igniter/durable_model" # canonical
require "igniter/companion"     # compatibility
```

## Non-Goals

- Do not remove `Igniter::Companion`.
- Do not remove `require "igniter/companion"`.
- Do not migrate `examples/application/companion` into a different product app.
- Do not rename the Companion app/product example.
- Do not change Ledger, Ledger Client, or Durable Model runtime semantics.
- Do not introduce core `Store[T]` / `History[T]` syntax.
- Do not attempt a Rubygems release.

## Required Shape

### 1. Package directory rename

Use a git-aware move if possible:

```text
packages/igniter-companion -> packages/igniter-durable-model
```

Keep history readable. If the move is too noisy, prefer a clean staged move over
manual recreation.

### 2. Gemspec rename

Rename:

```text
igniter-companion.gemspec -> igniter-durable-model.gemspec
```

Update gemspec metadata:

- `spec.name = "igniter-durable-model"`
- summary/description should use Durable Model language
- dependencies should remain equivalent
- files should include canonical and compatibility load paths

Do not publish or tag.

### 3. Gemfile/Rakefile/spec paths

Update package-local paths and require references so these work:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
```

If package-local `bundle exec rake spec` works, keep it working too.

### 4. Compatibility require shims

Inside the new package, keep:

```text
lib/igniter/companion.rb
lib/igniter/companion/record.rb
lib/igniter/companion/history.rb
lib/igniter/companion/receipts.rb
lib/igniter/companion/store.rb
```

These should load or alias Durable Model, not maintain a separate
implementation.

Preferred direction:

```text
durable_model/* owns implementation or canonical aliases
companion/* loads durable_model/* and exposes compatibility constants
```

Avoid split-brain constants.

### 5. Docs

Update public/package docs:

- root package README in the new directory
- package docs index in the new directory
- `docs/dev/package-map.md`
- `docs/dev/current-runtime-snapshot.md`
- `docs/research/igniter-lang-convergence-report.md` if needed
- any root docs that still present `igniter-companion` as the package

Important language:

```text
`igniter-durable-model` is the package.
`Igniter::DurableModel` is the canonical namespace.
`Igniter::Companion` is compatibility for the old package identity and for the
Companion app proof.
```

### 6. References and scripts

Search and update references carefully:

```bash
rg "igniter-companion|packages/igniter-companion|Igniter::Companion|require \"igniter/companion\""
```

Do not blindly replace every `Companion` word. Keep product/app references:

```text
examples/application/companion
Companion app
Companion product proof
```

### 7. Tests

Add/keep compatibility tests:

- canonical `require "igniter/durable_model"`
- compatibility `require "igniter/companion"`
- `Igniter::DurableModel::*` works
- `Igniter::Companion::*` aliases still work
- `from_manifest` works from both namespaces
- LedgerClient-backed Store works from canonical namespace

## Suggested Read Set

1. `packages/igniter-companion/docs/tracks/durable-model-namespace-adoption-v0.md`
2. `packages/igniter-companion/docs/proposals/companion-package-identity.md`
3. `docs/research/igniter-lang-convergence-report.md`
4. `packages/igniter-companion/igniter-companion.gemspec`
5. `packages/igniter-companion/Gemfile`
6. `packages/igniter-companion/Rakefile`
7. `packages/igniter-companion/lib/igniter/durable_model.rb`
8. `packages/igniter-companion/lib/igniter/companion.rb`
9. `packages/igniter-companion/spec/igniter/durable_model_spec.rb`
10. `docs/dev/package-map.md`
11. `docs/dev/current-runtime-snapshot.md`

Do not read the whole repository. This is a package identity/move slice.

## Acceptance

Done means:

- `packages/igniter-durable-model` exists and owns the package.
- `packages/igniter-companion` no longer contains the full package
  implementation.
- `igniter-durable-model.gemspec` is the package gemspec.
- Canonical require path works.
- Compatibility require path works.
- Docs point to `igniter-durable-model` as package identity.
- Companion app/product references remain Companion.
- Tests are green.

Required tests:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
```

Optional but recommended if dependency wiring changed:

```bash
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec packages/igniter-ledger/spec
```

## Final Notes

- Moved the package directory from `packages/igniter-companion` to
  `packages/igniter-durable-model` with `git mv`.
- Renamed the gemspec to `igniter-durable-model.gemspec` and updated gem
  identity to `igniter-durable-model`.
- Canonical implementation now lives under `lib/igniter/durable_model/*`.
- `lib/igniter/companion.rb` and `lib/igniter/companion/*` remain compatibility
  shims over `Igniter::DurableModel`.
- Updated package docs, package maps, research index links, and source-tree
  load paths in the Companion app proof to point at the new package directory.
- Companion app/product references remain Companion.

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-durable-model/package-rename-v0
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
