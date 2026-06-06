# Ledger TBackend Adapter Descriptor Package v0

Card: S2-R14-C2-P
Agent: `[Igniter-Lang Package Agent]`
Role: `bridge-agent`
Track: `ledger-tbackend-adapter-descriptor-package-v0`
Status: done
Date: 2026-05-07

Affected neighbor roles: `[Igniter-Lang Research Agent]`,
`[Igniter-Lang Compiler/Grammar Expert]`, `[Igniter-Lang Bridge Agent]`

## Purpose

Implement the metadata-only Ledger TBackend adapter descriptor slice in
`packages/igniter-ledger`.

The descriptor is evidence metadata only. It is not a Ledger adapter, does not
perform reads or writes, and does not bind RuntimeMachine temporal access.

## Namespace Decision

`Igniter::Ledger` is currently a pre-v1 alias for `Igniter::Store`.

The implementation therefore lives under:

```text
Igniter::Store::TBackendAdapterDescriptor
```

and is visible through:

```text
Igniter::Ledger::TBackendAdapterDescriptor
```

This follows the package's current internal `Igniter::Store` layout while
preserving the public `igniter-ledger` entrypoint.

## Shipped

- Added descriptor value object/builder from `metadata_snapshot` and
  `descriptor_snapshot` hashes.
- Computes canonical `descriptor_hash`.
- Computes canonical `descriptor_registry_hash`.
- Derives supported TBackend ops from Ledger Open Protocol op names.
- Derives metadata-only hook/capability/axis claims from snapshot content.
- Exposes requirement diagnostics for missing ops, hook methods, capabilities,
  axes, and schema fingerprint mismatch.
- Keeps non-authorization flags explicit.

## Non-Goals Preserved

- No `read_as_of` implementation.
- No `bihistory_at` implementation.
- No Ledger read/write/append/replay/compact/subscribe calls.
- No RuntimeMachine binding.
- No CompatibilityReport production integration.
- No migration behavior.

## Verification

```bash
BUNDLE_GEMFILE=packages/igniter-ledger/Gemfile bundle exec rspec \
  packages/igniter-ledger/spec/igniter/store/tbackend_adapter_descriptor_spec.rb
```

Observed result:

```text
9 examples, 0 failures
```

## Handoff

```text
Card: S2-R14-C2-P
Agent: [Igniter-Lang Package Agent]
Role: bridge-agent
Track: ledger-tbackend-adapter-descriptor-package-v0
Status: done

[D] Decisions
- Implemented the descriptor in Igniter::Store, visible through Igniter::Ledger
  because Ledger is currently an alias of Store.
- Kept the slice metadata-only and diagnostics-only.

[S] Shipped / Signals
- Descriptor construction, canonical hashes, requirement diagnostics, and
  non-authorization flags are package-local.

[T] Tests / Proofs
- Targeted package spec passes.

[R] Risks / Recommendations
- Future package slice can decide whether to add a deep-renamed
  Igniter::Ledger file namespace after the broader Store->Ledger rename.
- RuntimeMachine binding should wait for descriptor evidence review.

[Next] Suggested next slice
- Add CompatibilityReport consumption of descriptor evidence only after
  Architect approval.
```
