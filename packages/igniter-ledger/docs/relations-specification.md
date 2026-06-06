# Contract Persistence Relations

Status: research specification with app-local Companion slices landed. Not
accepted core DSL, package API, database planner, or Igniter Lang grammar.

## Core Claim

A persistence relation is a typed, manifest-visible edge between durable
capabilities.

It is not a database foreign key first. It is not an ORM association first. It
is a contract-level declaration that can later lower to validation, indexes,
foreign keys, projections, materialized views, cluster placement hints, or
language-level types.

## Relation Model

Minimal relation shape:

```text
Relation {
  name
  kind
  from
  to
  join
  cardinality
  integrity
  consistency
  projection
  enforced
}
```

Fields:

- `name`: stable relation identity in manifests and diagnostics.
- `kind`: semantic class, such as `reference`, `event_owner`, `receipt`, or
  `projection_input`.
- `from`: source capability name.
- `to`: target capability name.
- `join`: field mapping, such as `{ id: :tracker_id }`.
- `cardinality`: `one_to_one`, `one_to_many`, `many_to_one`, or `many_to_many`.
- `integrity`: current policy for missing or conflicting endpoints.
- `consistency`: `local`, `causal`, `eventual`, or `strong`.
- `projection`: optional graph contract that consumes the relation.
- `enforced`: false until a later accepted enforcement phase.

Formal reading:

```text
Relation[A, B] = named predicate over identity spaces of A and B
```

For persistence, the predicate is usually a join over durable fields:

```text
join(left, right) = left.id == right.tracker_id
```

## Relation Kinds

| Kind | Example | Meaning |
| --- | --- | --- |
| `reference` | Reminder -> User | mutable record references another record |
| `ownership` | Project -> Task | parent owns child record lifecycle |
| `event_owner` | Tracker -> TrackerLog | record owns or validates append-only events |
| `receipt` | Reminder -> CompanionAction | command/activity history references a subject |
| `projection_input` | Tracker + TrackerLog -> TrackerReadModel | durable capabilities feed a read model |
| `command_effect` | ReminderContract -> reminders | command may emit persistence operation |
| `materialization` | orders -> revenue_cube | operational data feeds analytical shape |

`event_owner` is the first Companion relation pressure.

## Semantics Ladder

Relations should graduate one phase at a time:

1. `declare`: metadata exists.
2. `manifest`: setup/readiness can report it.
3. `validate`: endpoints and join fields are checked.
4. `project`: graph read models can name and consume it.
5. `warn`: missing relation integrity can produce diagnostics.
6. `enforce`: writes can reject or require repair.
7. `place`: cluster/storage layers can use the relation for locality.

Companion has reached phases 1-4 for two relations and phase 5 as diagnostics:

- `declare`: `RELATION_BINDINGS`
- `manifest`: `/setup/manifest`
- `validate`: endpoint, kind, join-field, projection, and `enforced: false`
  checks
- `project`: `tracker_read_model` declares `tracker_logs_by_tracker` as an
  input relation; `comments_by_article` is manifest-only for now
- `warn`: relation health reports orphan history references as structured
  warnings

Companion has not reached `enforce` or `place`.

## Agent-Clean DSL

Prefer an explicit registry-level form first:

```ruby
relations do
  relation :tracker_logs_by_tracker,
           kind: :event_owner,
           from: :trackers,
           to: :tracker_logs,
           join: { id: :tracker_id },
           cardinality: :one_to_many,
           integrity: :validate_on_append,
           consistency: :local,
           projection: :tracker_read_model,
           enforced: false
end
```

This form is easy for agents, generators, and manifests. It avoids hiding the
cross-capability edge inside one endpoint.

## Human Sugar

Human-facing contract sugar can lower to the same relation manifest:

```ruby
contract :Tracker do
  persist key: :id, adapter: :sqlite

  field :id
  field :name
  field :template
  field :unit

  has_many :logs,
           history: :tracker_logs,
           foreign_key: :tracker_id,
           integrity: :validate_on_append
end

contract :TrackerLog do
  history key: :tracker_id, adapter: :sqlite

  field :tracker_id
  field :date
  field :value

  belongs_to :tracker,
             store: :trackers,
             foreign_key: :tracker_id,
             target_key: :id,
             on_missing: :reject
end
```

The sugar is optional. The explicit relation manifest is canonical.

## Projection DSL

Projection contracts should be able to name the relation without owning
persistence:

```ruby
projection :TrackerReadModel do
  reads :trackers
  reads :tracker_logs, via: :tracker_logs_by_tracker

  output :tracker_snapshots
end
```

Until a projection DSL exists, the current Companion shape is acceptable:

```text
TrackerReadModelContract.evaluate(trackers:, tracker_logs:, date:)
```

The manifest should still be able to say that this contract consumes the
relation.

## Manifest Shape

Target app-local manifest entry:

```ruby
{
  relations: {
    tracker_logs_by_tracker: {
      kind: :event_owner,
      from: :trackers,
      to: :tracker_logs,
      join: { id: :tracker_id },
      cardinality: :one_to_many,
      integrity: :validate_on_append,
      consistency: :local,
      projection: :tracker_read_model,
      enforced: false
    }
  }
}
```

Readiness should validate:

- `from` capability exists
- `to` capability exists
- endpoint kinds match relation kind
- join source field exists
- join target field exists
- projection exists when named
- relation is marked `enforced: false` unless an accepted track says otherwise

## Companion Slices

These have landed app-locally:

```ruby
RELATION_BINDINGS = {
  tracker_logs_by_tracker: {
    kind: :event_owner,
    from: :trackers,
    to: :tracker_logs,
    join: { id: :tracker_id },
    cardinality: :one_to_many,
    integrity: :validate_on_append,
    consistency: :local,
    projection: :tracker_read_model,
    enforced: false
  },
  comments_by_article: {
    kind: :event_owner,
    from: :articles,
    to: :comments,
    join: { id: :article_id },
    cardinality: :one_to_many,
    integrity: :validate_on_append,
    consistency: :local,
    projection: nil,
    enforced: false
  }
}.freeze
```

Acceptance:

- `/setup/manifest` includes `relations`
- readiness validates endpoints and join fields
- projection manifests include relation inputs where a projection exists
- relation health reports can emit structured warnings
- relation health can emit review suggestions
- smoke proves relation manifest, projection relation input, relation health,
  structured warnings, and setup endpoints
- no new core DSL keyword
- no DB foreign key or SQL index generation
- no write enforcement or automatic repair

## Current Companion Shape

The active app-local implementation uses:

```ruby
RELATION_BINDINGS = {
  tracker_logs_by_tracker: {
    kind: :event_owner,
    from: :trackers,
    to: :tracker_logs,
    join: { id: :tracker_id },
    cardinality: :one_to_many,
    integrity: :validate_on_append,
    consistency: :local,
    projection: :tracker_read_model,
    enforced: false
  },
  comments_by_article: {
    kind: :event_owner,
    from: :articles,
    to: :comments,
    join: { id: :article_id },
    cardinality: :one_to_many,
    integrity: :validate_on_append,
    consistency: :local,
    projection: nil,
    enforced: false
  }
}.freeze
```

Projection input metadata:

```ruby
PROJECTION_INPUT_BINDINGS = {
  tracker_read_model: {
    reads: %i[trackers tracker_logs],
    relations: %i[tracker_logs_by_tracker]
  }
}.freeze
```

Relation health reports:

- per relation status
- warning count
- structured warning payloads
- review suggestions shaped as command intents
- no mutation or repair execution

## Next App-Local Slice

Choose one:

- harden relation health summaries and setup output
- add manifest-only relation sugar in Companion, lowering to the explicit
  registry manifest
- add another relation only if it tests a new semantic kind, not another
  `event_owner`

Do not add enforcement, cascade behavior, DB foreign keys, relation planners, or
core DSL.

## Lang Lowering

The future language-level shape should stay compatible with:

```text
Store[Tracker]
History[TrackerLog]
Relation[Store[Tracker], History[TrackerLog]]
Projection[TrackerReadModel]
```

Possible future typed form:

```text
relation tracker_logs_by_tracker:
  Store[Tracker].id -> History[TrackerLog].tracker_id
  cardinality one_to_many
  integrity validate_on_append
```

The same relation can later inform:

- required indexes
- append validation
- projection plans
- materialized read models
- bitemporal correction joins
- cluster co-location of record partition and history head segment

## Non-Goals

Do not add yet:

- core relation DSL
- package-level relation runtime
- automatic join planner
- database foreign key generation
- cascade delete semantics
- distributed placement
- polymorphic relation syntax
- many-to-many sugar before a real app pressure exists
- relation enforcement by default

## Handoff

```text
[Architect Supervisor / Codex]
Track: docs/research/contract-persistence-relations.md
Status: research spec proposed for app-local Companion proof.
[D] App-local relation proofs landed for Tracker -> TrackerLog ->
TrackerReadModel and Article -> Comment.
[D] A relation is a typed manifest edge between persistence capabilities, not an
ORM association or DB foreign key first.
[R] Canonical form is explicit relation manifest; human sugar may lower to it.
[R] Relation phases must follow declare -> manifest -> validate -> project ->
warn -> enforce -> place.
[S] Companion is at declare/manifest/validate/project/warn for one projected
relation and one manifest-only relation; enforce/place remain deferred.
Next: keep relation health diagnostic-only and add another relation only if it
tests a new semantic kind.
Block: no core/package promotion until relation manifest proves useful.
```
