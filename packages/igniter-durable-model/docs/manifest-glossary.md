# Companion Persistence Manifest Glossary

Status date: 2026-04-30.
Scope: app-local Companion manifest vocabulary. Not public API.

## Claim

The Companion persistence manifest is now readable as a compact capability map.
Agents should use this glossary before changing persistence, relations,
materializer review flows, or future extraction boundaries.

## Reading Order

Read `/setup/manifest` top down:

1. `schema_version`
2. `records`
3. `histories`
4. `projections`
5. `commands`
6. `relations`
7. `summary`

Then read `/setup/materializer.json` for the compact review lifecycle status.
Read `/setup/materializer/descriptor-health.json` when changing the
materializer status descriptor.
Read `/setup/storage-plan.json` when discussing field/table lowerings. It is a
review-only sketch, not a DB schema or migration plan.
Read `/setup/storage-plan-health.json` when changing storage-plan vocabulary or
checking that it remains non-executing.
Read `/setup/storage-migration-plan.json` when discussing R2 storage-plan diffs.
It is a review-only migration candidate report, not a runner.
Read `/setup/storage-migration-plan-health.json` when changing R2 migration
candidate vocabulary or checking no-execution/no-SQL boundaries.
Read `/setup/field-type-plan.json` before changing field vocabulary, defaults,
enum domains, JSON fields, required keys, relation type checks, access paths,
or materializer dry-run output.
Read `/setup/field-type-health.json` when checking that R2a type validation
remains report-only and non-executing.
Read `/setup/relation-type-plan.json` before changing relation joins,
projection inputs, access-path sketches, FK discussions, or migration planning.
Read `/setup/relation-type-health.json` when checking that R2b relation type
compatibility remains report-only and non-enforcing.
Read `/setup/access-path-plan.json` before discussing future `store_read`
dependencies, cache/coalescing, projection consumers, reactive invalidation, or
typed effect intent.
Read `/setup/access-path-health.json` when checking that R2c access paths remain
metadata only and do not become runtime graph nodes.
Read `/setup/health.json` for the compact report-only current-state packet.
Read `/setup/handoff.json` first when rotating context between agents.

Use `/setup/manifest/glossary-health.json` to check whether the manifest still
contains the required glossary terms.
The same report is also summarized in `/setup` as `manifest_glossary`.

## Terms

`schema_version`

- Current value: `1`.
- Means the manifest shape is intentionally versioned.
- Does not imply a public API guarantee.

`storage`

- Canonical durable descriptor.
- `storage.shape: :store` means future `Store[T]`.
- `storage.shape: :history` means future `History[T]`.
- `persist` and `history` remain compatibility aliases beside `storage`.

`storage_plan_sketch`

- Review-only R1 lowerings exposed at `/setup/storage-plan.json`.
- Maps records to storage/table name candidates, primary key candidates,
  columns from field descriptors, index candidates, and scope/query
  descriptors.
- Maps histories to append-only table candidates with partition key candidates.
- Includes adapter type mapping candidates such as JSON fields to
  `:json_document`.
- Keeps `schema_changes_allowed: false` and `sql_generation_allowed: false`.
- Does not imply a table-per-contract guarantee, migration runner, DB planner,
  index creation, or backfill.

`storage_plan_health`

- Report-only drift check exposed at `/setup/storage-plan-health.json`.
- Validates no-gate/no-grant descriptor policy, disabled schema changes,
  disabled SQL generation, Store/History lowerings, key candidates,
  field-derived columns, adapter type candidates, index/scope sources, and
  summary counts.
- Does not feed into runtime execution or authorize migrations.

`storage_migration_plan`

- Review-only R2 storage-plan diff exposed at
  `/setup/storage-migration-plan.json`.
- Compares current and previous storage-plan descriptors when a previous plan is
  supplied; current app state passes `nil` previous plan and reports stable.
- Classifies storage candidates as stable, additive, destructive, or ambiguous
  based on columns, indexes, scopes, keys, adapter, and append-only changes.
- Emits candidates with `review_only: true`,
  `migration_execution_allowed: false`, and `sql_generation_allowed: false`.
- Does not create migrations, generate SQL, alter DB schema, backfill data, or
  request capabilities.

`storage_migration_plan_health`

- Report-only R2 drift check exposed at
  `/setup/storage-migration-plan-health.json`.
- Validates descriptor policy, status vocabulary, record/history report shapes,
  report and candidate counts, and candidate review-only/no-execution/no-SQL
  flags.
- Does not authorize migration execution or SQL generation.

`field_type_plan`

- Report-only R2a validation exposed at `/setup/field-type-plan.json`.
- Validates field descriptor vocabulary, defaults, enum domains, JSON fields,
  datetime values, required key presence, and current seeded payload shape.
- Preserves `persist -> Store[T]` and `history -> History[T]` explicitly in the
  descriptor.
- Does not gate runtime, change schema, generate SQL, execute materializer
  steps, or grant capabilities.

`field_type_health`

- Report-only drift check exposed at `/setup/field-type-health.json`.
- Validates descriptor policy, Store/History lowerings, supported field types,
  required-key coverage, enum/json checks, no type issues, summary counts, and
  no schema/SQL/materializer execution.
- Does not authorize relation enforcement, DB migrations, access-path nodes, or
  typed write execution.

`relation_type_plan`

- Report-only R2b relation compatibility plan exposed at
  `/setup/relation-type-plan.json`.
- Checks join field descriptors for `Relation[Store[A], History[B]]` edges.
- Treats `:unspecified` fields as inferred compatibility so legacy/simple
  fields do not become premature public type commitments.
- Keeps `relation_enforcement_allowed: false` and
  `foreign_key_generation_allowed: false`.

`relation_type_health`

- Report-only drift check exposed at `/setup/relation-type-health.json`.
- Validates descriptor policy, Relation/Store/History lowerings, report-only
  enforcement, join reports, missing-field checks, mismatch checks, summary
  counts, and no FK/enforcement capability.
- Does not authorize FK generation, relation enforcement, DB migrations, or
  runtime graph-node changes.

`access_path_plan`

- Report-only R2c access-path sketch exposed at `/setup/access-path-plan.json`.
- Describes record/history/relation read paths, lookup kind, key bindings,
  scope/filter sources, cache/coalesce hints, and projection reactive consumer
  hints.
- Includes current APIs such as `all`, `find`, `scope`, `where`, and `count`,
  plus future-only index/join descriptors marked `implemented: false`.
- Keeps `store_read_node_allowed: false`, `runtime_planner_allowed: false`, and
  `cache_execution_allowed: false`.

`access_path_health`

- Report-only drift check exposed at `/setup/access-path-health.json`.
- Validates descriptor policy, Store/History/Relation lowerings, path
  descriptors, no mutation, cache hint presence, projection consumers, summary
  counts, and no runtime planner/cache execution.
- Does not authorize StoreRead graph nodes, cache execution, reactive runtime
  wiring, DB indexes, or relation enforcement.

`records`

- Durable record capabilities.
- Record APIs expose `all`, `find`, `save`, `update`, `delete`, `clear`,
  `scope`, and `command`.
- Writes still apply only through the app boundary.

`histories`

- Append-only capabilities.
- History APIs expose `append`, `all`, `where`, and `count`.
- Do not treat histories as CRUD records.

`operation_descriptors`

- Canonical operation vocabulary beside compatibility `operations` lists.
- Fields: `name`, `kind`, `target_shape`, `mutates`, `boundary`.
- `target_shape` is `:store`, `:history`, or `:none`.
- `boundary: :app` means graph contracts compute intent; app/store applies it.

`commands`

- Graph-owned behavior contracts.
- Commands return result plus normalized mutation intent.
- Current mutation operations: `record_append`, `record_update`,
  `history_append`, and `none`.
- Durable Model mirrors command metadata into Ledger `kind: :command`
  descriptors during schema registration.
- Ledger metadata snapshots expose commands by owner/name, but Ledger does not
  execute app commands.
- Command descriptors may carry normalized app policy metadata:
  `policy.requires` and `policy.review`. Ledger stores this descriptor metadata
  for introspection, but does not evaluate capabilities or approvals.
- `Store#command_intent` turns command metadata into a pure
  `kind: :command_intent` object for app-boundary previews/projections.
- Command intents carry `execution_allowed: false`; they do not write, append,
  publish, or call app callbacks.
- `Store#command_operation_plan` turns a command intent into a dry-run
  `kind: :command_operation_plan` preview with target/value/event shape,
  validation status, errors, and warnings.
- Operation plans carry `execution_allowed: false`; app-boundary apply/audit
  remains a separate explicit layer.
- `Store#command_activity_event` projects intents/plans into app-safe
  `kind: :command_activity_event` summaries for UI previews, audit candidates,
  and agent monitors.
- Activity events carry `store_fact_exposed: false`,
  `value_hash_exposed: false`, and `execution_allowed: false`; they do not
  persist audit histories or expose planned record values.
- `Store#append_command_activity` is the explicit audit persistence step. It
  appends the app-safe summary to built-in `History[CommandActivity]` and
  returns `CommandActivityReceipt`.
- `CommandActivityReceipt` intentionally omits fact ids, value hashes, and
  causation; it records audit status, not command execution.
- `Store#command_policy_decision` checks a command plan against app-local
  required capabilities and review approvals. It returns an app-safe
  `CommandPolicyDecision` with allowed/denied/review_required status and does
  not mutate storage or write audit history.
- `Store#apply_command` is the explicit app-owned command application boundary.
  It accepts ready `CommandOperationPlan` values and lowers supported operations
  through Durable Model `write`/`append`, not through Ledger-side command
  execution.
- `CommandApplyReceipt` reports applied/rejected status, mutation intent,
  target, warnings, errors, and whether activity was recorded. It intentionally
  omits fact ids, value hashes, causation, and the raw activity receipt.
- `Store#command_lifecycle` folds matching `CommandActivity` history into an
  app-safe `CommandLifecycle` read model for UI and agents. It returns
  `:unknown`, `:intended`, `:planned`, `:policy_denied`, `:review_required`,
  `:rejected`, or `:applied` without mutating storage, evaluating policy, or
  exposing raw receipts/fact ids/value hashes.
- `Store#command_lifecycle_events` returns the typed filtered
  `CommandActivity` timeline for apps that need the full activity history.
- `Store#command_flow` is a transparent app-owned orchestrator over intent,
  plan, activity event, policy decision, optional apply, and lifecycle. It
  defaults to preview mode, preserves or generates an app-local request id, and
  never hides mutation: storage changes only happen with `mode: :apply`.
- `CommandFlow` serializes an app-safe command story and omits raw fact ids,
  value hashes, causation, and planned record values from its `to_h`.
- `Store#command_flow_slice` reads `CommandActivity` history over an explicit
  temporal horizon and returns `CommandFlowSlice`, an app-safe projection with
  grouped request items and status/command/actor counts.
- Temporal slice semantics: `since:` is the inclusive lower bound, `as_of:` is
  the inclusive observation horizon, both lower through existing replay paths,
  and `generated_at` records when the slice object was created.
- Slice items group by `metadata[:request_id]` when present and omit raw fact
  ids, value hashes, causation, command values, and provider payloads.
- `Store#command_flow_monitor` evaluates explicit plain-data rules against a
  `CommandFlowSlice` and returns `CommandFlowMonitorResult`.
- Monitor rules support total/status/command/actor/subject/request metrics,
  ratios, comparison operators, and info/warning/critical severity. Matched
  rules become app-safe observations/alerts; no scheduling or delivery happens.
- `CommandFlowMonitorResult` folds status to `:critical` for critical alerts,
  `:warning` for warning alerts, and `:ok` otherwise. Matched `:info` alerts do
  not worsen the overall status.
- `Store#register_command_flow_view` registers an app-local named operational
  view descriptor over command-flow slices and monitor rules. Duplicate names
  overwrite the previous descriptor.
- `Store#_command_flow_views` returns compact app-safe
  `CommandFlowViewDescriptor` snapshots keyed by view name. This registry is
  local Durable Model metadata and does not add a Ledger descriptor kind.
- `Store#command_flow_view` evaluates a registered descriptor by merging
  descriptor filters with call-time overrides, building a `CommandFlowSlice`,
  evaluating `CommandFlowMonitorResult`, and returning `CommandFlowView`.
- `CommandFlowViewDescriptor` stores name, owner, filters, horizon, monitor
  rules, advisory action policy, metadata, and app-boundary safety flags.
- `CommandFlowView` stores the evaluated status, horizon mode, filters, slice,
  monitor, summary, and generated timestamp. It exposes `ok?`, `warning?`,
  `critical?`, `live?`, `reproducible?`, `pin_required?`, and
  `actionable?`.
- Operational view horizons default to `:live`; `as_of: :latest` is live, while
  fixed `as_of`, fixed `rule_version`, and bounded `fact_scope` infer
  `:reproducible` unless mode is declared explicitly.
- Operational view action policy is advisory, not authorization. Mutation-grade
  actions can require a pinned/reproducible horizon, but real writes still go
  through command policy and apply APIs.
- Command-flow operational views are read models only: no mutation, command
  activity append, command execution, scheduler, notification delivery, or
  Ledger protocol operation happens during evaluation.
- `Store#pin_command_flow_view` evaluates a named operational view with a fixed
  reproducible horizon and returns `CommandFlowViewPin` decision evidence.
- Pinning synthesizes an app-local bounded command-activity fact scope when the
  descriptor does not provide one, sets `mode: :reproducible`, and uses an
  explicit `rule_version` (`:current_rules` when the descriptor is unset or
  live/latest).
- `CommandFlowViewPin` records pinned/blocked status, meaning status, action,
  actor, capabilities, missing capabilities, horizon, evaluated view, stable
  receipt, structured errors, metadata, and app-boundary safety flags.
- Pin receipts use `kind: :command_flow_view_pin_receipt` and an app-local
  `cfvp_...` receipt id. They are decision artifacts, not Ledger fact ids.
- Forbidden, unknown, missing-capability, or unpinned-horizon actions return
  blocked pin evidence with structured error codes. Missing view names and
  malformed actions remain API errors.
- Pinning is still read-model behavior: no business record mutation, command
  execution, command activity append, durable pin registry, scheduler,
  notification delivery, or Ledger protocol operation happens.
- `CommandFlowDecision` is a built-in app-owned History stream for persisted
  command-flow view decisions. It uses `history_name: :command_flow_decisions`
  and partitions by `owner`.
- `Store#append_command_flow_decision` explicitly persists a
  `CommandFlowViewPin` as one `CommandFlowDecision` entry. Pinning itself
  remains non-persistent unless this API is called.
- `CommandFlowDecisionReceipt` is an app-safe append receipt with app-local
  `decision_receipt_id`, original pin `receipt_id`, decision metadata, and no
  Ledger fact id, value hash, or causation exposure.
- `Store#command_flow_decisions` replays decision history by owner partition and
  filters by view name, action, actor, status, meaning status, receipt id, and
  temporal window.
- Decision entries persist both the originating pin `receipt_id` and the
  app-local `decision_receipt_id` returned by
  `CommandFlowDecisionReceipt`. Both are app-safe ids; neither exposes Ledger
  fact ids.
- `Store#command_flow_decision_review` builds a compact
  `CommandFlowDecisionReview` over persisted decisions using the same filters
  and temporal windows as `command_flow_decisions`.
- `CommandFlowDecisionReview` exposes total counts plus counts by status,
  meaning status, view, action, actor, missing capabilities, errors, warnings,
  latest decision timestamp, and rule-derived findings.
- Decision review rules are app-local read-model checks over summary metrics.
  Findings fold review status to `:critical`, `:warning`, or `:ok`; they do not
  authorize or execute anything.
- `Store#command_flow_evidence_profile` builds a portable
  `CommandFlowEvidenceProfile` from a named operational view, optional pin,
  decision review, compact decision entries, package-local packet candidates,
  and logical links.
- Evidence profiles fold status conservatively across view, pin, and review
  artifacts and fold meaning status without overclaiming reproducibility.
- Evidence packet candidates are Durable Model local shapes, not Igniter-Lang
  `ObsPacket` values. Packet subjects and links use stable app-safe
  `durable-model://...` refs for owners, views, pins, decisions, and decision
  receipts.
- Evidence profiles are packaging/read-model artifacts only: they do not append
  decision history, append command activity, mutate business records, execute
  commands, add transport endpoints, or add Ledger protocol operations.
- `Store#export_command_flow_evidence_profile` exports an existing
  `CommandFlowEvidenceProfile` into a deterministic `CommandFlowEvidenceExport`
  envelope without re-evaluating the profile.
- `Store#command_flow_evidence_export` builds an evidence profile and exports it
  in one read-only call.
- Evidence exports support `:app_safe`, `:summary_only`, and `:hash_payloads`
  privacy policies. Redactions record removed or hashed paths.
- Evidence export canonical JSON and content hashes are package-local v0
  canonicalization for comparisons and fixtures, not a global cross-language
  serializer promise.
- Evidence export diagnostics are advisory app-safe signals for blocked,
  unknown, critical, empty, omitted, or hash-only evidence.
- Evidence exports do not persist exports automatically, append decisions,
  append command activity, mutate records, execute commands, add endpoints, or
  add Ledger protocol operations.
- `Store#verify_command_flow_evidence_export` and
  `Store#verify_command_flow_evidence_archive` recompute SHA256 over canonical
  JSON and return `CommandFlowEvidenceExportVerification`.
- `Store#archive_command_flow_evidence_export` explicitly persists a verified
  `CommandFlowEvidenceExport` into `CommandFlowEvidenceArchive` history.
  Invalid exports return a rejected app-safe receipt and are not appended.
- `CommandFlowEvidenceArchive` partitions by owner and stores app-safe archive
  identity: owner, view, action, actor, export id, content hash, privacy,
  status, meaning status, profile kind, canonical JSON, diagnostics,
  redactions, and metadata.
- `CommandFlowEvidenceArchiveReceipt` records app-local archive receipt ids and
  never exposes Ledger fact ids, value hashes, or causation internals.
- `Store#command_flow_evidence_archives` replays archives by owner and filters
  by view, action, actor, export id, content hash, privacy, status, meaning
  status, and temporal window.
- Evidence archive is explicit only: no export is archived automatically, and
  archive/verification do not rebuild profiles, append decisions, append command
  activity, mutate records, execute commands, add endpoints, or add Ledger
  protocol operations.
- Command-flow decision history is separate from `CommandActivity`: decisions
  describe human/agent/app decisions made from operational views, while command
  activity describes command attempts.
- Decision append persists pinned and blocked decisions, merges explicit
  metadata over pin metadata, and still does not mutate business records,
  execute commands, append command activity, or add Ledger protocol operations.

`effects`

- Metadata-only persistence intents derived from commands.
- Current store operations are `store_write`, `store_append`, and `none`.
- Effects preserve `command -> mutation_intent -> app boundary`; side effects
  still happen in app-owned code, not inside Ledger.
- Durable Model mirrors effects into Ledger `kind: :effect` descriptors during
  schema registration.
- Command intents embed the derived effect metadata so apps can decide how to
  project or apply the intent later.
- Operation plans also embed effect metadata so previews can show the intended
  store/history operation without mutating storage.
- Activity events intentionally omit raw effect payload values; they summarize
  status, target, errors, and warnings for app-facing surfaces.
- Command activity history is separate from effect application. Recording audit
  activity never mutates the target record or planned business history.
- Lifecycle projection is separate from command application. It only reads
  already-recorded activity and folds status deterministically.
- Command flow orchestration is not a workflow engine. It stitches existing
  app-boundary objects together and keeps preview non-mutating.
- Command flow slices are read models, not aggregate tables. They read retained
  activity history and fold status for dashboards/agents.
- Command flow monitors are deterministic read-model evaluations, not
  schedulers, notifications, descriptor registries, or policy gates.
- Applying commands is still app-owned behavior. Ledger stores descriptors and
  facts, but does not run command callbacks or decide policy/capability.
  `CommandPolicyDecision` is a summary, not an authorization token.

`projections`

- Graph-owned read models.
- `reads` lists capability inputs.
- `relations` lists typed relation inputs.
- Projections do not own writes.

`relations`

- Typed manifest edges, not ORM associations.
- Compatibility fields include `kind`, `from`, `to`, `join`, `cardinality`,
  `integrity`, `consistency`, `projection`, and `enforced`.
- Canonical `descriptor` includes source/target storage shapes, lowering
  metadata, and enforcement policy.

`relation.descriptor.enforcement`

- Current mode: `:report_only`.
- `enforced: false` must remain true for this app-local proof.
- Relation health may warn, but it does not reject writes or repair data.

`materializer_status`

- Compact status packet exposed at `/setup/materializer.json`.
- Alias over materializer supervision, not a new capability.
- Shows phase, next action, attempt audit, approval audit, and command intents.
- Includes canonical `descriptor` with `schema_version: 1`,
  `kind: :materializer_status`, review-only state, history targets, command
  intents, and audit counts.
- Must not grant write/git/test/restart capabilities.
- `grants_capabilities: false` and `execution_allowed: false` are part of the
  descriptor contract.

`materializer_status_descriptor_health`

- Report-only drift check exposed at
  `/setup/materializer/descriptor-health.json`.
- Verifies schema version, descriptor kind, review-only state, no capability
  grants, no execution, app-boundary requirement, history targets, command
  intents, audit counts, and status/phase alignment.
- `status: :stable` means the compact status descriptor still preserves the
  materializer safety boundary.
- Does not make persistence readiness stricter.

`manifest_glossary_health`

- Report-only drift check exposed at `/setup/manifest/glossary-health.json`.
- Also surfaced in `/setup` as a summary signal.
- Current stable state checks nine terms: schema version, record storage,
  record aliases, history storage, history aliases, operation descriptors,
  relation descriptors, projection reads, and command app boundaries.
- `status: :stable` means the current manifest matches this glossary.
- `status: :drift` means a term disappeared or stopped matching the glossary.

`setup_health`

- Report-only summary exposed at `/setup/health.json`.
- Includes `descriptor` with `schema_version: 1`, `kind: :setup_health`,
  `report_only: true`, `gates_runtime: false`, and
  `grants_capabilities: false`.
- Folds persistence readiness, relation health, manifest glossary health,
  materializer status descriptor health, and infrastructure loop health.
- Relation warnings become `review_items`, not runtime blockers.
- Does not grant capabilities and does not make readiness stricter.

`setup_handoff`

- Compact context-rotation packet exposed at `/setup/handoff.json`.
- Includes `descriptor` with `schema_version: 1`, `kind: :setup_handoff`,
  `report_only: true`, `gates_runtime: false`, and
  `grants_capabilities: false`.
- Carries reading order, manifest scale, current materializer phase, and next
  action.
- Reading order includes both handoff acceptance packets, so lifecycle progress
  can be checked without mutating setup state.
- Reading order also includes `/setup/handoff/lifecycle.json` as the compact
  stage map.
- Reading order includes `/setup/handoff/lifecycle-health.json` as the drift
  check for that stage map.
- Reading order includes `/setup/handoff/supervision.json` as the compact agent
  context packet.
- Reading order includes `/setup/handoff/packet-registry.json` as the indexed
  setup packet surface.
- Reading order includes `/setup/handoff/extraction-sketch.json` as the
  package-placement sketch without public API promise.
- Reading order includes `/setup/handoff/promotion-readiness.json` as the
  explicit package/API promotion blocker report.
- Reading order includes `/setup/handoff/digest.json` and
  `/setup/handoff/digest.txt` as the structured and plain-text compact diagram
  plus next-read summary.
- Reading order includes `/setup/handoff/next-scope.json` as the supervised
  backlog packet for the current reversible slice.
- Reading order includes `/setup/handoff/next-scope-health.json` as the drift
  check for supervised backlog shape.
- Carries `document_rotation` with the compact public docs and private track to
  read before older thread history.
- Carries `architecture_constraints` for app-local scope, no public API promise,
  no materializer execution, report-only relations, no approval grants, and
  `persist` / `history` lowerings.
- Carries `next_scope` with small reversible app-local candidates and forbidden
  moves.
- Carries `acceptance_criteria` for the recommended next scope, including proof
  markers and non-goals.
- It is a handoff/read model, not an execution or approval surface.

`setup_handoff_lifecycle`

- Read-only stage map exposed at `/setup/handoff/lifecycle.json`.
- Composes `setup_handoff`, `setup_handoff_acceptance`,
  `setup_handoff_approval_acceptance`, and `materializer_status`.
- Starts as `status: :pending`, `current_stage: :attempt_receipt`.
- Moves to `current_stage: :approval_receipt` after explicit attempt receipt.
- Becomes `status: :complete` only after explicit approval receipt while still
  keeping `gates_runtime: false` and `grants_capabilities: false`.

`setup_handoff_lifecycle_health`

- Report-only drift check exposed at `/setup/handoff/lifecycle-health.json`.
- Validates lifecycle descriptor shape, source packets, stage order, read views,
  explicit POST mutations, current stage, and next action.
- Stays outside `setup_health` because it depends on `setup_handoff`, which
  already depends on `setup_health`.

`setup_handoff_supervision`

- Single agent context packet exposed at `/setup/handoff/supervision.json`.
- Composes setup health, setup handoff, lifecycle, lifecycle health, and
  materializer status.
- Reports lifecycle status/stage, materializer phase, no-grant/no-execution
  signals, packet refs, and next action.
- It is not a runtime gate, approval, or execution surface.

`setup_handoff_packet_registry`

- Read-only packet index exposed at `/setup/handoff/packet-registry.json`.
- Lists setup/handoff packet endpoints, packet roles, descriptor boundaries,
  reading order, and explicit receipt POST paths.
- All indexed packets must remain report-only, `gates_runtime: false`, and
  `grants_capabilities: false`.

`setup_handoff_extraction_sketch`

- Read-only landing-zone packet exposed at
  `/setup/handoff/extraction-sketch.json`.
- Keeps current scope `companion_app_local`.
- Names extraction candidates for `igniter-extensions` and
  `igniter-application`, while reserving future `igniter-persistence`.
- Must keep `package_promise: false` and `package_split_now: false`.

`setup_handoff_promotion_readiness`

- Report-only blocker packet exposed at
  `/setup/handoff/promotion-readiness.json`.
- Current expected status is `:blocked`.
- Names why package/API promotion is not ready yet.
- Allowed next steps must keep Companion app-local and gather repeated pressure.

`setup_handoff_digest`

- Compact human/agent packet exposed at `/setup/handoff/digest.json` and as
  plain text at `/setup/handoff/digest.txt`.
- Includes a short ASCII text diagram, highlights, and recommended next reads.
- Composes supervision, extraction sketch, and promotion readiness.
- Remains report-only with no runtime gate and no capability grants.

`setup_handoff_next_scope`

- Supervised backlog packet exposed at `/setup/handoff/next-scope.json`.
- Pulls `next_scope` and `acceptance_criteria` out of the large handoff packet.
- Names the recommended app-local slice, candidate list, forbidden moves,
  explicit receipt POST paths, and current lifecycle next action.
- Remains report-only and does not grant execution, approval, or package/API
  promotion capability.

`setup_handoff_next_scope_health`

- Drift-check packet exposed at `/setup/handoff/next-scope-health.json`.
- Validates descriptor no-gate/no-grant policy, recommended candidate presence,
  scoped candidate endpoints, explicit setup POST mutation paths, forbidden
  moves, acceptance alignment, and lifecycle next action vocabulary.
- Remains outside `/setup/health` so the next-scope backlog can be supervised
  without becoming a global runtime readiness gate.

`setup_handoff_acceptance`

- Report-only acceptance status exposed at `/setup/handoff/acceptance.json`.
- Evaluates the recommended handoff scope without executing it.
- Starts as `status: :pending` on clean setup state.
- Becomes `status: :satisfied` only after explicit
  `POST /setup/materializer-attempts/record`.
- Also has an explicit convenience alias:
  `POST /setup/handoff/acceptance/record`.
- Must keep `gates_runtime: false` and `grants_capabilities: false`.

## `setup_handoff_approval_acceptance`

Report-only follow-up acceptance packet for the approval receipt step.

- Exposed at `/setup/handoff/approval-acceptance(.json)`.
- Starts as `status: :pending` on clean setup state.
- Becomes `status: :satisfied` only after explicit attempt and approval receipt
  POSTs.
- Also has an explicit convenience alias:
  `POST /setup/handoff/approval-acceptance/record`.
- Must keep `applied_count: 0`, `gates_runtime: false`, and
  `grants_capabilities: false`.

## Current Lowerings

```text
persist alias -> storage.shape=:store -> Store[T]
history alias -> storage.shape=:history -> History[T]
relation descriptor -> Relation[Store[A], History[B]]
command mutation -> normalized operation intent -> app boundary
projection reads -> graph-owned read model
setup health -> report-only current-state packet
setup handoff -> compact agent context rotation packet
```

## Do Not Infer

- Do not infer DB tables, SQL indexes, foreign keys, cascades, or migrations.
- Do not infer runtime contract generation from `WizardTypeSpec`.
- Do not infer capability grants from approval receipts.
- Do not infer public API stability from manifest vocabulary.

## Next Safe Slice

Use this glossary to keep future slices small:

- add missing manifest terms here before expanding implementation
- update `manifest_glossary_health` when this glossary intentionally changes
- keep compatibility aliases until lowerings stabilize
- prefer report-only diagnostics before runtime enforcement
- keep setup/read endpoints side-effect-free
