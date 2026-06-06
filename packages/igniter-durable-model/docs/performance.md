# Companion Contract Performance Signal

Status date: 2026-04-30.
Scope: Companion app-local POC signal, not a core runtime verdict.

## Claim

The current slowdown is not caused by the new persistence contracts being
intrinsically slow. The strongest signal is repeated setup packet recomputation
and oversized aggregate `/setup` rendering.

## Measurement

Initial measurement before app-local memoization:

Measured against the live Companion server on `127.0.0.1:9298`:

```text
/setup                         ~11450ms
/setup/manifest                ~1ms
/setup/storage-plan.json       ~1ms
/setup/field-type-plan.json    ~1ms
/setup/relation-type-plan.json ~2ms
/setup/access-path-plan.json   ~3ms
/setup/health.json             ~22ms
/                             ~40ms
```

Measured inside the Companion service:

```text
persistence_manifest           <1ms
storage_plan_sketch            <1ms
field_type_plan                ~1ms
relation_type_plan             ~1ms
access_path_plan               ~3-4ms
setup_health                   ~22-25ms
setup_handoff                  ~40-46ms
setup_handoff_supervision      ~0.4s
setup_handoff_packet_registry  ~1.2s
setup_handoff_digest           ~4.8s
```

After app-local packet memoization plus invalidation on generated record/history
mutations:

```text
/setup                         ~12ms first read, ~1ms warm read
/setup/manifest                ~1ms
/setup/storage-plan.json       <1ms
/setup/field-type-plan.json    <1ms
/setup/relation-type-plan.json <1ms
/setup/access-path-plan.json   <1ms
/setup/health.json             <1ms warm read
/                             ~1ms warm read
```

```text
persistence_manifest           <1ms
storage_plan_sketch            <1ms
field_type_plan                <1ms
relation_type_plan             <1ms
access_path_plan               <1ms
setup_health                   ~3-4ms
setup_handoff                  <1ms
setup_handoff_digest           ~1ms
setup_handoff_packet_registry  <1ms
setup_handoff_supervision      <1ms
repeat packet reads            ~0ms
```

## Diagnosis

The POC currently computes setup packets by calling service methods directly.
Those methods recursively call other packet methods, so one aggregate request can
recompute the same materializer, handoff, lifecycle, readiness, and manifest
packets many times.

The problem shape:

```text
/setup
  -> setup_handoff_digest
     -> setup_handoff_supervision
        -> setup_health
        -> setup_handoff
        -> setup_handoff_lifecycle
        -> materializer_status
  -> setup_handoff_packet_registry
     -> many of the same packets again
  -> setup_handoff_supervision
     -> many of the same packets again
  -> huge Hash#inspect
```

## Optimization Ladder

1. Request-local packet memoization. **App-local proof implemented.**
   Compute each setup/materializer/persistence packet once per request or per
   service read cycle.

2. Packet snapshot boundary.
   Build one `SetupPacketSnapshot`/`CompanionPacketSnapshot` value and pass it to
   aggregate contracts instead of letting every method call rebuild dependencies.

3. Smaller `/setup`.
   Keep `/setup` as an index/summary and push heavy packets to their specific
   `.json` endpoints.

4. Compiled manifest cache.
   `Igniter::Contract` already caches compiled graphs per class/profile. The app
   can additionally cache parsed persistence manifests per contract class.

5. Structured serialization path.
   Prefer JSON packet endpoints over giant `Hash#inspect` for aggregate setup
   surfaces.

6. Profiling guard.
   Add a POC-only timing report such as `/setup/performance.json` before deeper
   runtime optimization work.

## Boundary

Do not optimize yet by:

- changing core contract execution semantics
- adding graph-native StoreRead nodes
- adding global mutable caches
- hiding setup packet cost by removing validation evidence
- treating this POC measurement as a package-level benchmark

Do optimize next by making repeated packet computation visible and then
memoized at the Companion app boundary.

## Next Slice

Recommended reversible slice:

- keep the current app-local packet memoization
- add a compact `/setup/performance.json` only if the signal returns
- consider packet snapshot boundary if aggregate packet shape grows again
- keep individual packet endpoints unchanged
- keep all persistence/materializer packets report-only
