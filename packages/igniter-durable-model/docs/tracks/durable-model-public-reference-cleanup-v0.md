# Track: Durable Model Public Reference Cleanup v0

Status: done
Owner: [Architect Supervisor / Codex]
Agent: Package Agent / Companion+Store (pkg:companion-store)
Target package: `packages/igniter-durable-model`

## Context

The physical package rename has landed:

```text
packages/igniter-companion -> packages/igniter-durable-model
igniter-companion.gemspec -> igniter-durable-model.gemspec
```

The canonical Ruby namespace is:

```ruby
Igniter::DurableModel
```

Compatibility remains:

```ruby
Igniter::Companion
require "igniter/companion"
```

The next problem is public/reference drift. Many current docs and examples still
present `igniter-companion` or `Igniter::Companion` as the main package/API.
Some of those references are historical and should remain. Others are current
onboarding surfaces and should move to Durable Model language.

## Goal

Make current public/package-facing references consistently use
`igniter-durable-model` and `Igniter::DurableModel`, while preserving
`Igniter::Companion` only as compatibility or app/product terminology.

This is a cleanup and alignment slice after rename. It should not change runtime
behavior.

## Non-Goals

- Do not remove `Igniter::Companion` compatibility.
- Do not remove `require "igniter/companion"`.
- Do not rename `examples/application/companion`.
- Do not rewrite historical track handoffs just because they mention the old
  name.
- Do not alter Ledger, Ledger Client, or Durable Model semantics.
- Do not perform gem release/publish work.

## Required Shape

### 1. Durable Model package README cleanup

Update `packages/igniter-durable-model/README.md` and `README.ru.md`:

- canonical examples should use `require "igniter/durable_model"`
- canonical classes should include `Igniter::DurableModel::Record` /
  `Igniter::DurableModel::History`
- canonical stores should use `Igniter::DurableModel::Store`
- canonical manifest generation should use `Igniter::DurableModel.from_manifest`
- `Igniter::Companion` should appear only in a clearly marked compatibility
  section

Do not erase the Companion app/product proof narrative where it means the
example application.

### 2. Package playground cleanup

Update package playground examples under:

```text
packages/igniter-durable-model/playground/
```

Current demo code should use Durable Model as the primary API unless the demo is
explicitly a compatibility demo.

Keep one compact compatibility example or spec proving `Igniter::Companion`
still works.

### 3. Current docs cleanup

Update current public/current docs where old package identity is misleading:

- `docs/dev/package-map.md`
- `docs/dev/current-runtime-snapshot.md`
- `docs/research/project-status-horizon-report.md`
- `packages/README.md`
- relevant current `packages/igniter-ledger/README.md` sections
- relevant current `packages/igniter-ledger-client/docs/proposals/*` sections

Preferred language:

```text
igniter-durable-model is the typed Record/History facade over igniter-ledger.
Igniter::DurableModel is canonical.
Igniter::Companion remains compatibility and app/product proof vocabulary.
```

### 4. Historical docs policy

Do not churn old track files unless they are actively misleading in current
read paths.

Accept old references inside:

- old completed `docs/tracks/*`
- archived convergence logs
- handoff records
- old package-agent transcripts

If a historical doc is frequently linked from current docs, add a short note at
the top instead of rewriting the whole history.

### 5. Specs and require checks

Add or keep focused tests that prove both surfaces:

```ruby
require "igniter/durable_model"
require "igniter/companion"
```

and:

```ruby
Igniter::DurableModel::Store
Igniter::Companion::Store
```

point at the intended compatible implementation.

## Suggested Read Set

1. `packages/igniter-durable-model/docs/tracks/durable-model-package-rename-v0.md`
2. `packages/igniter-durable-model/README.md`
3. `packages/igniter-durable-model/README.ru.md`
4. `packages/igniter-durable-model/playground/setup.rb`
5. `packages/igniter-durable-model/playground/schema/task.rb`
6. `packages/igniter-durable-model/playground/schema/tracker.rb`
7. `packages/igniter-durable-model/playground/demos/07_network.rb`
8. `packages/igniter-durable-model/playground/demos/08_server_lifecycle.rb`
9. `docs/dev/package-map.md`
10. `docs/dev/current-runtime-snapshot.md`
11. `docs/research/project-status-horizon-report.md`
12. `packages/README.md`
13. `packages/igniter-ledger/README.md`
14. `packages/igniter-ledger-client/docs/proposals/ledger-client-adoption-map.md`

Do not read the whole repository. Use `rg` to find current references, then
classify them as current docs, package examples, or historical records.

## Acceptance

Done means:

- New/current user-facing examples prefer `Igniter::DurableModel`.
- Compatibility examples still mention `Igniter::Companion` explicitly as
  compatibility.
- Current package map and runtime snapshot use `igniter-durable-model`.
- Ledger and Ledger Client current docs point app users to Durable Model, not
  the old package name.
- Historical track docs are not churned unnecessarily.
- Tests remain green.

Required tests:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec rspec packages/igniter-durable-model/spec
bundle exec rspec packages/igniter-ledger-client/spec
```

Optional smoke check if playground code changed:

```bash
BUNDLE_GEMFILE=packages/igniter-durable-model/Gemfile bundle exec ruby packages/igniter-durable-model/playground/run.rb
```

Only run the playground smoke if it is already stable in the current package;
otherwise report why it was skipped.

## Final Notes

- Canonical README and playground examples now use `require "igniter/durable_model"`
  and `Igniter::DurableModel::*`.
- `Igniter::Companion` remains documented only as compatibility/app proof
  vocabulary in current public package docs.
- Current package, Ledger, Ledger Client, and project status docs now point
  app users toward `igniter-durable-model`.

## Handoff Format

```text
[Package Agent / Companion+Store]
Track: igniter-durable-model/public-reference-cleanup-v0
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
