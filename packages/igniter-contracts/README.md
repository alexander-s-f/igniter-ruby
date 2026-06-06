# igniter-contracts

Public embedded kernel package for Igniter:

- contracts and DSL
- graph model and compiler
- execution/runtime primitives
- diagnostics, events, and core extension seams

Primary entrypoints:

- `require "igniter-contracts"`
- `require "igniter/contracts"`
- `require "igniter/lang"` for the additive Lang foundation

Current proof path:

- [Contract Class DSL](../../docs/guide/contract-class-dsl.md)
- [Igniter Lang Foundation](../../docs/guide/igniter-lang-foundation.md)
- [Getting Started](../../docs/guide/getting-started.md)

Current implementation focus:

- `Kernel`
- `Profile`
- `Environment`
- `Registry` / `OrderedRegistry`
- `Pack` / `BaselinePack`

## Intended Use

Use `igniter-contracts` when Igniter is embedded inside another host such as:

- Rails applications
- scripts and jobs
- existing service runtimes

This package is the lower-layer dependency that other runtime shapes should
build on top of. It should not pull:

- application hosting
- server/runtime containers
- cluster coordination
- web rendering or schema-rendering packages

It also should not depend on the legacy core implementation. Legacy code remains
reference/parity material during the rewrite, not the public architecture.

## Current Shape

`igniter-contracts` starts from its own internal primitives:

- registries
- kernel/profile lifecycle
- environment sugar over a finalized profile
- packs
- a tiny baseline pack

## Ergonomics

You can still work directly with `Kernel` and `Profile`, but the public facade
now gives two equal authoring paths.

For the low-level embedded kernel API, compile or run a block directly:

```ruby
environment = Igniter::Contracts.with

result = environment.run(inputs: {}) do
  const :tax_rate, 0.2
  output :tax_rate
end
```

For app code and human-edited contract files, use the class DSL:

```ruby
class PriceContract < Igniter::Contract
  define do
    input :order_total, type: :numeric
    input :country, type: :string

    compute :gross_total, depends_on: %i[order_total country] do |order_total:, country:|
      order_total * (country == "UA" ? 1.2 : 1.0)
    end

    output :gross_total
  end
end

contract = PriceContract.new(order_total: 100, country: "UA")
contract.result.gross_total
contract.update_inputs(order_total: 150)
contract.output(:gross_total)
```

Compute nodes may also use `call:` for service objects or callable classes:

```ruby
compute :gross_total, depends_on: %i[order_total country], call: Pricing::GrossTotal
```

Contractable services expose a small service protocol to compute nodes:

```ruby
class BodyBatteryScorer
  include Igniter::Contracts::Contractable

  contractable :call do
    role :migration_candidate
    stage :shadowed
    meta :domain, :wellness
    input :sleep_hours
    input :training_minutes
    output :score
  end

  def call(sleep_hours:, training_minutes:)
    sleep_score = observe(:sleep_score) { [[sleep_hours / 8.0, 1.0].min * 40, 0].max }
    training_score = observe(:training_score) { training_minutes <= 45 ? 10 : 2 }

    success(score: [[45 + sleep_score + training_score, 100].min, 0].max.round)
  end
end

compute :body_battery,
        depends_on: %i[sleep_hours training_minutes],
        using: BodyBatteryScorer
```

`using:` returns a normalized payload with `outputs`, `observations`, `error`,
and `success`. The service owns its internal implementation; Igniter owns the
graph boundary and result protocol.

Declared `input` and `output` names are validated at the protocol boundary.
Missing inputs or missing declared outputs return a failure payload instead of
raising through the caller. Extra outputs are allowed for now, which keeps
contractable services useful during migration and discovery.

`role`, `stage`, and `meta` travel in result metadata. Host layers such as
`igniter-embed` can use those fields as defaults for observation and migration
wrappers.

Use `output:` when the graph should expose one named service output as the
compute value:

```ruby
compute :score,
        depends_on: %i[sleep_hours training_minutes],
        using: BodyBatteryScorer,
        output: :score
```

Additional helpers:

- `Igniter::Contracts.build_kernel(*packs)`
- `Igniter::Contracts.build_profile(*packs)`
- `Igniter::Contracts.with(*packs)`

## Verification

Use focused package specs and runnable examples as the current proof path:

```bash
bundle exec rspec packages/igniter-contracts/spec spec/current
ruby examples/run.rb smoke
```

Focused contracts/lang checks:

```bash
ruby examples/run.rb run contracts/class_pricing
ruby examples/run.rb run contracts/class_callable
ruby examples/run.rb run contracts/embed_class_registration
ruby examples/run.rb run contracts/contractable_shadow
ruby examples/run.rb run contracts/step_result
ruby examples/run.rb run contracts/lang_foundation
```

For narrow changes, run RuboCop on the changed files. Full-project RuboCop
currently includes pre-existing archived/research offenses, so changed-file
lint is the practical gate for focused package slices; this is a caveat, not a
quality target.

## Igniter Lang Foundation

`require "igniter/lang"` loads a small contracts-facing Lang namespace.
Currently this is an additive reference surface over the existing contracts
runtime:

- `Igniter::Lang.ruby_backend` wraps current compile, execute, diagnose, and
  verify APIs.
- `History`, `BiHistory`, `OLAPPoint`, and `Forecast` are immutable
  definition-time descriptors that can be attached as operation metadata.
- `VerificationReport` is read-only and follows current compilation findings.
  Its `metadata` hash can carry generic report-only sections such as
  `diagnostics`, `receipts`, `model_validity_reports`,
  `scenario_comparison_reports`, and `review_receipts`.
- `MetadataManifest` reports declared `type:`, `return_type:`, `deadline:`,
  and `wcet:` metadata.
- `DiagnosticPayload` is a generic report-only carrier for metadata-only
  diagnostic hashes from projection, pipeline, availability, or future
  operation profiles. It includes a redaction policy and rejects raw refs in v0.
- `ReceiptPayload` is a generic report-only carrier for metadata-only receipts
  such as request, execution, idempotency, or external bridge receipt shapes.
  It includes the same redaction defaults and does not authorize execution.
- `SchemaCompatibilityDiagnostic` is an immutable report-only compatibility
  value object with required evidence links and an optional single-hop
  `migration_profile`.

Metadata manifest fields are declared, not enforced. `return_type`, `deadline`,
and `wcet` appear in reports with `enforced: false`; they do not add runtime
checks, warnings, deadline monitoring, or `ExecutionResult` changes.
Verification metadata carrier sections are opaque serializable hashes. When
present, they require an explicit `redaction_policy`, force
`raw_ref_export: false`, reject raw refs, and produce a `carrier_manifest` with
section counts, profile names, and report-only enforcement flags. Future opaque
sections can be carried under `metadata[:custom_sections]`; OSINT-style
profiles and future compiler-pipeline proof profiles remain metadata-only
custom sections rather than public package API, including separated compiler
pass reports.
Generic diagnostic payloads are serialized through `VerificationReport` as
`diagnostic_payloads`; generic receipt payloads use `receipt_payloads`. Neither
surface authorizes package adapters, real data export, provider bridges,
operation execution, readiness checks, Ledger integration, or runtime
enforcement.
Schema compatibility diagnostics follow the same boundary:
`report_only: true`, `runtime_enforced: false`, and no migration execution.
The optional migration profile only serializes evidence, including blocked
OOF-MR3 wrong-fingerprint cases.

Try the compact proof:

```bash
ruby examples/contracts/lang_foundation.rb
```

See [Igniter Lang Foundation](../../docs/guide/igniter-lang-foundation.md) for
the short guide.

This is not a compatibility promise for the next Igniter-Lang compiler release.
Until Igniter-Lang provides a stable release-candidate export fixture, Ruby
should treat compiler POC material as redacted report-only evidence payloads,
not executable language semantics.
