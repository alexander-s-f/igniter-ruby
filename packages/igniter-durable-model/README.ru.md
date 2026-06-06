# igniter-durable-model

Durable Model: слой Record/History уровня приложения поверх `igniter-ledger`.

> Канонический оригинал — [README.md](README.md) (English).

Статус: пакет теперь называется `igniter-durable-model`, а канонический Ruby
namespace — `Igniter::DurableModel`.

## Цель

Этот пакет — **Durable Model слой над `igniter-ledger` с точки зрения
прикладного кода**.

Он существует по двум причинам:

1. **Пользовательская поверхность** — показывает, как должна выглядеть работа с фактами из кода контрактов/приложений: типизированные `Record`, append-only `History`, scope-запросы, реактивные подписки.

2. **Давление на ядро** — каждая новая возможность на этом уровне выявляет пробелы, неудобства или баги в `igniter-ledger`. Это намеренно. Инсайты фиксируются в секции [Давление и инсайты](#давление-и-инсайты) ниже.

### Метафора туннеля

```
examples/application/companion   ←── app-level contracts, manifests, materializer
                   │
                   │  копают навстречу друг другу
                   ▼
  packages/igniter-durable-model      ←── Durable Model DSL поверх igniter-ledger
                   │
                   ▼
  packages/igniter-ledger          ←── факты, WAL, scope, reactive (Rust/Ruby FFI)
```

**Точка сближения**: когда `PersistenceSketchPack` в `examples/application/companion`
начнёт работать через `Igniter::DurableModel::Store` вместо blob-JSON в SQLite.

---

## Архитектура

```
lib/igniter/durable_model.rb
lib/igniter/durable_model/
  record.rb    — Record mixin: store_name, field, scope DSL → типизированные объекты
  history.rb   — History mixin: history_name, field → append-only события
  store.rb     — Store: register, write, read, scope, append, replay, on_scope
```

```ruby
require "igniter/durable_model"
```

### `Record`

Оборачивает `Store[T]` из igniter-ledger. Последнее записанное значение — текущее состояние.

```ruby
class Reminder
  include Igniter::DurableModel::Record
  store_name :reminders

  field :title
  field :status, default: :open
  field :due,    default: nil

  scope :open, filters: { status: :open }
  scope :done, filters: { status: :done }, cache_ttl: 30
end
```

### `History`

Оборачивает `History[T]` из igniter-ledger. Append-only, ключи генерируются автоматически.

```ruby
class TrackerLog
  include Igniter::DurableModel::History
  history_name :tracker_logs
  partition_key :tracker_id   # включает partition replay

  field :tracker_id
  field :value
  field :notes, default: nil
end
```

### `Store`

Оркестратор — хранит инстанс `IgniterStore`, знает о зарегистрированных схемах.

```ruby
store = Igniter::DurableModel::Store.new         # in-memory (по умолчанию)
store = Igniter::DurableModel::Store.new(        # file-backed WAL
  backend: :file,
  path:    "/tmp/durable-model.wal"
)

store.register(Reminder)   # регистрирует AccessPath для каждого scope

store.write(Reminder, key: "r1", title: "Buy milk", status: :open)
store.read(Reminder,  key: "r1")                 # => #<Reminder key="r1" ...>
store.scope(Reminder, :open)                     # => [#<Reminder ...>, ...]
store.scope(Reminder, :open, as_of: checkpoint)  # time-travel

store.append(TrackerLog, tracker_id: "t1", value: 8.5)
store.replay(TrackerLog)                         # => [#<TrackerLog ...>, ...]
store.replay(TrackerLog, since: cutoff)          # с фильтром по времени
store.replay(TrackerLog, partition: "sleep")     # фильтр по partition_key

store.causation_chain(Reminder, key: "r1")       # цепочка мутаций для отладки
store.lineage(Reminder, key: "r1")               # компактное provenance-proof
```

### Compatibility

Старый load path `lib/igniter/companion` и namespace `Igniter::Companion`
остаются доступными для pre-rename callers и Companion app proof:

```ruby
require "igniter/companion"

Igniter::Companion::Store # => Igniter::DurableModel::Store
```

#### Remote Ledger Client boundary

Для remote Ledger deployments предпочтителен стандартный
`igniter-ledger-client`, а не старый proof через `backend: :network`:

```ruby
client = Igniter::LedgerClient.remote_http(
  "http://127.0.0.1:7300/v1/dispatch",
  events_url: "http://127.0.0.1:7300/v1/events"
)
store = Igniter::DurableModel::Store.new(client: client)

store.register(Reminder)
store.write(Reminder, key: "r1", title: "Buy milk", status: :open)
store.read(Reminder, key: "r1")
store._commands
store._effects
intent = store.command_intent(Reminder, :complete, key: "r1")
plan = store.command_operation_plan(intent)
event = store.command_activity_event(plan)
store.append_command_activity(event)
decision = store.command_policy_decision(plan,
  actor: "user-1",
  capabilities: [:reminder_complete])
store.apply_command(plan, policy_decision: decision, audit: true)
store.command_lifecycle(
  owner: :reminders,
  command: :complete,
  subject_key: "r1")
store.command_flow(Reminder, :complete,
  key: "r1",
  actor: "user-1",
  capabilities: [:reminder_complete],
  mode: :preview)
store.command_flow_slice(
  owner: :reminders,
  status: :applied,
  since: Time.utc(2026, 1, 1))
store.command_flow_monitor(
  owner: :reminders,
  rules: [{
    name: :denials,
    metric: :status_count,
    status: :policy_denied,
    op: :>,
    value: 0
  }])
store.register_command_flow_view(:reminder_flow_health,
  owner: :reminders,
  command: :complete,
  horizon: { mode: :live, as_of: :latest },
  action_policy: {
    inspect: true,
    mutate: :requires_pinned_horizon
  },
  rules: [{
    name: :denials,
    metric: :status_count,
    status: :policy_denied,
    op: :>,
    value: 0
  }])
store.command_flow_view(:reminder_flow_health)
store.pin_command_flow_view(:reminder_flow_health,
  action: :mutate,
  capabilities: [:dispatch_review])
pin = store.pin_command_flow_view(:reminder_flow_health,
  action: :inspect,
  capabilities: [:dispatch_review])
store.append_command_flow_decision(pin)
store.command_flow_decisions(
  owner: :reminders,
  view_name: :reminder_flow_health)
store.command_flow_decision_review(
  owner: :reminders,
  view_name: :reminder_flow_health,
  rules: [{
    name: :blocked,
    metric: :status_count,
    status: :blocked,
    op: :>=,
    value: 1
  }])
store.command_flow_evidence_profile(
  view_name: :reminder_flow_health,
  action: :inspect,
  capabilities: [:dispatch_review],
  decision_rules: [{
    name: :blocked,
    metric: :status_count,
    status: :blocked,
    op: :>=,
    value: 1
  }])
store.command_flow_evidence_export(
  view_name: :reminder_flow_health,
  action: :inspect,
  privacy: :summary_only)
export = store.command_flow_evidence_export(
  view_name: :reminder_flow_health,
  action: :inspect,
  privacy: :summary_only)
store.verify_command_flow_evidence_export(export)
store.archive_command_flow_evidence_export(export,
  metadata: { case_id: "ops-1" })
store.command_flow_evidence_archives(
  owner: :reminders,
  view_name: :reminder_flow_health)

store.register(TrackerLog)
store.append(TrackerLog, tracker_id: "sleep", value: 8.5)
store.replay(TrackerLog)
```

В client-backed v0 поддержаны `register`, `write`, `read`, `append`, обычный
`replay`, `replay(partition:)`, `scope`, `on_scope`, declared one-to-many
relation auto-wire, typed `resolve`, `_relations`, projection descriptor
registration, command/effect descriptor registration, `_projections`,
`_commands`, `_effects`, read-only `_scatters`, `command_policy_decision`,
`apply_command`, `command_lifecycle`, `command_lifecycle_events`,
`command_flow`, `command_flow_slice`, `command_flow_summary`,
`command_flow_monitor`, `register_command_flow_view`, `_command_flow_views`,
`command_flow_view`, `pin_command_flow_view`,
`append_command_flow_decision`, `command_flow_decisions`,
`command_flow_decision_review`, `command_flow_evidence_profile`,
`command_flow_evidence_export`, `export_command_flow_evidence_profile`,
`verify_command_flow_evidence_export`, `archive_command_flow_evidence_export`,
`command_flow_evidence_archives`, `metadata_snapshot` и `descriptor_snapshot`,
а также `causation_chain` и `lineage`. Partition replay проходит через Ledger replay
filter и использует Ledger partition indexes, когда запрос обслуживает Ledger
protocol interpreter. Relation support в v0 понижает
поддержанные one-to-many декларации в Ledger relation descriptors. Projection,
command и effect support — metadata-only: Ledger хранит descriptors, но не
исполняет app commands или callbacks. Прямой `register_scatter` пока требует
embedded Ledger engine path и явно поднимает `NotImplementedError`. Provenance
support read-only и compact: Durable Model экспонирует
`causation_chain`/`lineage`, а Ledger Client `fact_ref` возвращает только
metadata и не открывает произвольный `fact_by_id`.

Command support состоит из двенадцати слоёв: descriptor metadata
(`_commands`/`_effects`), pure `CommandIntent` objects, dry-run
`CommandOperationPlan` previews, app-safe `CommandActivityEvent` summaries,
explicit `CommandActivity` audit history append, explicit
`CommandPolicyDecision`, explicit `Store#apply_command` и `CommandLifecycle`
read models, плюс transparent `CommandFlow` orchestration. `CommandFlowSlice`
добавляет temporal operational read models поверх command activity;
`CommandFlowMonitorResult` добавляет deterministic rule evaluation поверх этих
slices. `CommandFlowViewDescriptor` и `CommandFlowView` добавляют named reusable
operational views, которые связывают filters, horizon defaults, monitor rules и
advisory action policy для dashboards и agents. `CommandFlowViewPin`
превращает named view в explicit app-owned pinned decision evidence с
reproducible horizon и stable app-local receipt shape.
`CommandFlowDecision` и `CommandFlowDecisionReceipt` добавляют explicit
app-owned decision history для сохранения pinned или blocked decisions только
по явному запросу. `CommandFlowDecisionReview` добавляет compact read model
поверх persisted decisions с summary metrics и advisory findings.
`CommandFlowEvidenceProfile` собирает view, optional pin, decision review,
decision entries, package-local packet candidates и logical links для UI,
agents, exports и future bridge code. `CommandFlowEvidenceExport` добавляет
deterministic package-local canonicalization, content hashes, export ids,
privacy redactions и diagnostics для evidence profiles. Будущая app security
infrastructure остаётся вне этого пакета. `CommandFlowEvidenceArchive`,
`CommandFlowEvidenceArchiveReceipt` и
`CommandFlowEvidenceExportVerification` добавляют explicit archive persistence
и hash verification для evidence exports.
`Store#command_intent`,
`Store#command_operation_plan` и
`Store#command_activity_event` строят только данные. `Store#append_command_activity`
— явный шаг audit persistence: он пишет только app-safe summary и возвращает
`CommandActivityReceipt`. `Store#command_policy_decision` суммирует app-owned
capability/review metadata без мутаций storage. `Store#apply_command` — явная
app-owned граница применения: она может требовать или принимать policy decision,
применяет ready allowed plans через существующие Durable Model `write`/`append`
APIs, может записывать applied/rejected activity, возвращает
`CommandApplyReceipt` и всё ещё не раскрывает fact ids/value hashes и не просит
Ledger исполнять commands. `Store#command_lifecycle` — read model поверх
`CommandActivity` history: он сворачивает intended/planned/rejected/
policy_denied/review_required/applied activity для UI и agents без исполнения
commands или оценки policy. `Store#command_flow` — transparent app-owned
orchestrator поверх тех же объектов. Он по умолчанию работает в `mode: :preview`,
генерирует или сохраняет request id, не мутирует storage в preview mode и
применяет команду только через `mode: :apply`. `Store#command_flow_slice` читает
`CommandActivity` history по явному temporal horizon (`since:` inclusive lower
bound, `as_of:` inclusive observation horizon), сворачивает requests в app-safe
slice items и отдаёт counts для dashboards и agents без raw Ledger facts или
command values. `Store#command_flow_monitor` оценивает explicit plain-data
rules поверх slice и возвращает app-safe `CommandFlowMonitorResult` с
observations, alerts и статусом `:ok`/`:warning`/`:critical`. Он не планирует
задачи, не отправляет notifications, не мутирует storage и не добавляет
Ledger-side monitor runtime.
`Store#register_command_flow_view` записывает только app-local descriptor;
`Store#command_flow_view` оценивает этот descriptor через slice и monitor result
и возвращает app-safe named report без мутаций, audit append, command execution,
scheduler, notification delivery или Ledger protocol surface. Live views могут
помечать mutation-grade actions как требующие pinned horizon; reproducible views
выводятся из fixed `as_of`, fixed `rule_version` и bounded `fact_scope`, если
mode не указан явно.
`Store#pin_command_flow_view` оценивает named view с fixed reproducible horizon,
проверяет advisory action policy/capabilities и возвращает
`CommandFlowViewPin` evidence с compact app-local receipt. Blocked actions
возвращают structured errors и ничего не исполняют.
`Store#append_command_flow_decision` явно сохраняет pinned или blocked decision
evidence в `CommandFlowDecision` history и возвращает app-safe
`CommandFlowDecisionReceipt`. `Store#command_flow_decisions` replay-ит эту
history по owner partition с view/action/actor/status/meaning/receipt и
temporal filters. Decision history отделена от `CommandActivity` и не мутирует
records, не исполняет commands, не append-ит command activity и не добавляет
Ledger protocol surface.
`Store#command_flow_decision_review` строится поверх persisted decision history
и возвращает `CommandFlowDecisionReview` с counts by status, meaning status,
view, action, actor, missing capabilities, errors, warnings и simple
rule-derived findings. Decision entries сохраняют и pin `receipt_id`, и
app-local `decision_receipt_id`; ни один из них не является Ledger fact id.
`Store#command_flow_evidence_profile` упаковывает текущий operational view,
optional pin evidence, persisted decision review, compact decision entries,
bridge-ready package-local packet candidates и stable logical links. Он не
append-ит decisions или command activity, не мутирует records, не исполняет
commands и не зависит от Igniter-Lang observation packets.
`Store#export_command_flow_evidence_profile` экспортирует existing profile без
re-evaluation; `Store#command_flow_evidence_export` строит и экспортирует за
один read-only call. Exports поддерживают `:app_safe`, `:summary_only` и
`:hash_payloads` privacy policies, записывают redactions/diagnostics и дают
package-local v0 canonical JSON плюс SHA256 content hashes и `cfe_...` export
ids.
`Store#verify_command_flow_evidence_export` и
`Store#verify_command_flow_evidence_archive` пересчитывают SHA256 поверх
canonical JSON и возвращают app-safe verification results.
`Store#archive_command_flow_evidence_export` явно сохраняет только verified
exports в `CommandFlowEvidenceArchive` history; invalid exports возвращают
rejected archive receipt и не append-ятся. `Store#command_flow_evidence_archives`
replay-ит archive history по owner с view/action/actor/export/hash/privacy/
status/meaning и temporal filters.

### Нормализованные receipts

`write` и `append` возвращают объекты-receipts с метаданными мутации.
Неизвестные методы делегируются на вложенный record/event:

```ruby
receipt = store.write(Reminder, key: "r1", title: "Buy milk")
receipt.mutation_intent          # => :record_write
receipt.fact_id                  # => "550e8400-..."
receipt.value_hash               # => "a3b1c2..."
receipt.causation                # => nil (первая запись) или предыдущий value_hash
receipt.title                    # => "Buy milk"  (делегировано на Reminder)
receipt.record                   # => #<Reminder ...>

receipt = store.append(TrackerLog, tracker_id: "sleep", value: 8.5)
receipt.mutation_intent          # => :history_append
receipt.timestamp                # => 1714483200.123
receipt.value                    # => 8.5  (делегировано на TrackerLog)
receipt.event                    # => #<TrackerLog ...>
```

### Реактивные подписки

```ruby
store.on_scope(Reminder, :open) do |store_name, payload|
  # вызывается при инвалидации scope-кэша
  puts "#{store_name} changed — refresh your view"
end
```

Подписчик **не** вызывается на каждый write — только когда scope-кэш был прогрет
запросом до этого, а следующий write его инвалидировал. Lazy-семантика из igniter-ledger
(см. [Инсайты](#давление-и-инсайты)).
В embedded-режиме второй аргумент — имя scope. В client-backed режиме подписка
идёт через события Ledger client, а второй аргумент — свежие записи этого scope.

---

## Запуск тестов

```bash
# Скомпилировать igniter-ledger (один раз):
cd ../igniter-ledger
PATH="$HOME/.cargo/bin:$PATH" bundle exec rake compile

# Запустить суиту Durable Model:
cd ../igniter-durable-model
bundle exec rake spec
```

---

## Давление и инсайты

Живой журнал. Каждый раз, когда Durable Model слой выявляет несоответствие или баг
в нижележащем слое, это фиксируется здесь с датой, симптомом, причиной,
исправлением и уроком.

---

### [2026-04-30] Float-coercion в `ruby_to_json_inner`

**Симптом**: тест с `TrackerLog#value = 7.0` получал обратно Integer `7`.

**Причина**: в `fact.rs` использовался `i64::try_convert(val)` для определения
числового типа. Magnus вызывает Ruby-метод `to_i` при конвертации, поэтому
`Float(7.0).to_i` → `7`, `Float(8.5).to_i` → `8`.

**Исправление** (в `igniter-ledger/ext/igniter_store_native/src/fact.rs`):
```rust
// Было (неточно — coerce-ит Float через to_i):
if let Ok(i) = i64::try_convert(val) { return serde_json::json!(i); }
if let Ok(f) = f64::try_convert(val) { return serde_json::json!(f); }

// Стало (точная проверка Ruby-типа):
if let Some(int) = RbInteger::from_value(val) {
    if let Ok(n) = int.to_i64() { return serde_json::json!(n); }
}
if let Some(flt) = RbFloat::from_value(val) {
    return serde_json::json!(flt.to_f64());
}
```

**Урок**: Magnus's `T::try_convert` проходит через Ruby coercion-протокол.
Для точного type-dispatch нужны `RbInteger::from_value` / `RbFloat::from_value`.

---

### [2026-04-30] Lazy-инвалидация scope-кэша

**Наблюдение**: scope-consumer не вызывается на первый write — только если
scope-кэш был прогрет запросом до этого.

**Это намеренное поведение**: `ReadCache` удаляет scope-записи при инвалидации,
но нечего удалять если кэш пустой → нет записей → нет уведомлений.

**Последствие для Durable Model**: `on_scope` документируется как
"уведомление об изменении прогретого кэша", не "уведомление о каждой мутации".
Для реакции на каждую мутацию нужен другой механизм (event bus / WAL tail).

**Открытый вопрос для igniter-ledger**: стоит ли добавить `eager: true` опцию
в `AccessPath`, которая регистрирует consumer как point-write listener
независимо от состояния кэша?

---

### [2026-04-30] Partition queries для History

**Добавлена возможность**: `partition_key :field_name` на `History`-классе; `Store#replay(partition: "value")` фильтрует события по этому полю.

**Реализация**: partition key хранится в value payload (не в ключе факта), поэтому фильтрация происходит на Ruby-слое после того, как `@inner.history(...)` возвращает все события для данного store. Регистрация нового `AccessPath` не нужна.

**Проверка сходимости**: check `history_partition_query` в `StoreConvergenceSidecarContract` проходит с `partition_replay_count == 2` и `partition_replay_values == [7.0, 8.5]`.

---

### [2026-04-30] Нормализованные receipts (`WriteReceipt` / `AppendReceipt`)

**Добавлена возможность**: `Store#write` возвращает `WriteReceipt`; `Store#append` — `AppendReceipt`. Оба несут `mutation_intent`, `fact_id`, `value_hash` и делегируют неизвестные методы на вложенный record/event.

**Давление**: raw `IgniterStore` возвращает `FactData`-подобный объект с `id`/`value_hash`/`causation`/`timestamp`. Обёртка в типизированные receipts на Durable Model слое не позволяет утечь деталям store во внешний код.

**Следующий открытый вопрос** (`pressure.next_question`): `:manifest_generated_record_history_classes` — автогенерация `Record`/`History`-классов из декларации `persistence_manifest` без фиксации финального DSL.

---

### [2026-04-30] Manifest-generated Record/History классы

**Добавлена возможность**: `Igniter::DurableModel.from_manifest(manifest, store:)` генерирует анонимный `Record` или `History` класс из хэша `persistence_manifest` приложения. Диспатч по `manifest[:storage][:shape]` (`:store` → `Record`, `:history` → `History`).

```ruby
klass = Igniter::DurableModel.from_manifest(
  Companion::Contracts::Reminder.persistence_manifest,
  store: :reminders
)
# klass включает Record, поля + scopes объявлены

klass = Igniter::DurableModel.from_manifest(
  Companion::Contracts::TrackerLog.persistence_manifest,
  store: :tracker_logs
)
# klass включает History, с partition_key + полями
```

**Что генерируется из манифеста**:
- Поля: `name` + `default:` (если `attributes[:default]` присутствует)
- Scopes (только Record): `name` + `filters:` (из `attributes[:where]`)
- Partition key (History): `history.key`, fallback на `storage.key`

**Gap закрыт немедленно**: см. следующую запись.

---

### [2026-04-30] Имя store в манифесте (`storage.name`)

**Gap закрыт**: `persistence_manifest_for` теперь выводит имя store из имени класса контракта через snake_case + наивное множественное число (`Reminder` → `:reminders`, `TrackerLog` → `:tracker_logs`) и включает как `storage[:name]`.

```ruby
manifest[:storage]  # => { shape: :store, name: :reminders, key: :id, adapter: :sqlite }
```

**`from_manifest` теперь не требует явного `store:`**:

```ruby
klass = Igniter::DurableModel.from_manifest(Contracts::Reminder.persistence_manifest)
klass.store_name  # => :reminders  (из манифеста)

klass = Igniter::DurableModel.from_manifest(manifest, store: :override)
klass.store_name  # => :override  (явный приоритет)
```

Бросает `ArgumentError` если в манифесте нет `storage.name` и `store:` не передан — старый API продолжает работать.

**Следующий открытый вопрос** (`pressure.next_question`): `:companion_store_backed_app_flow` — подключить `Igniter::DurableModel::Store` на app-уровне, чтобы `persist :reminders` текло через facts/WAL вместо blob-JSON/SQLite.

---

### [2026-04-30] Portable field types

**Возможность добавлена**: DSL `field` теперь принимает `type:` и `values:`. `from_manifest` зеркалирует их из `attributes[:type]` и `attributes[:values]` в дескрипторе манифеста.

```ruby
# Явно:
field :status, type: :enum, values: %i[open done], default: :open
field :title,  type: :string

# Из манифеста (класс Article с типизированными полями):
klass = Igniter::DurableModel.from_manifest(Contracts::Article.persistence_manifest)
klass._fields[:status]  # => { type: :enum, values: [:draft, :published, :archived], default: :draft }
klass._fields[:title]   # => { type: :string, values: nil, default: nil }
```

**Только аннотация**: `type:` хранится как метаданные в `_fields`, но не принуждает значения при чтении. Coercion — отдельная будущая задача.

**Evidence**: app-flow sidecar 13/13 стабильно — `typed_fields_mirrored`, `enum_values_mirrored`, `typed_record_round_trip` проходят.

**Следующий открытый вопрос** (`pressure.next_question`): `:mutation_intent_to_app_boundary` — должен ли `WriteReceipt.mutation_intent` напрямую попасть в историю действий приложения, или нужен проекционный слой?

---

### [2026-04-30] Mutation intent to app boundary

**Доказательство получено**: `[Architect Supervisor / Codex]` реализовал `CompanionReceiptProjectionSidecar` на стороне приложения — 12/12 стабильно.

**Ответ**: Проекционный слой обязателен. `WriteReceipt` не передаётся в историю действий напрямую. Схема:

```ruby
# Package receipt (внутренний)
receipt = store.write(reminder_class, ...)
# receipt.mutation_intent  => :record_write
# receipt.fact_id          => "uuid..."      ← не выходит наружу
# receipt.value_hash       => "blake3..."    ← не выходит наружу

# App projection (паттерн границы)
app_receipt = {
  kind:              :store_write_receipt,
  source:            :igniter_durable_model_store,
  target:            :reminders,
  subject_id:        "reminder-1",
  status:            :recorded,
  mutation_intent:   receipt.mutation_intent,   # ← сохраняется
  store_fact_exposed:  false,
  value_hash_exposed:  false
}
```

**Граница**: `fact_id` и `value_hash` — внутренности хранилища, они останавливаются на границе пакета. `mutation_intent` пересекает границу, потому что описывает семантику операции, а не детали хранения.

**Evidence**: `companion_receipt_projection_sidecar` 12/12 стабильно (`strategy: :small_app_receipt`).

**Следующий открытый вопрос** (`pressure.next_question`): `:index_metadata` — должны ли декларации индексов из манифеста (уникальные, составные) зеркалироваться в дескриптор генерируемого класса?

---

### [предстоящее] `nil` vs absent поля на чтении

**Гипотеза** (не проверена): если поле не было записано в value (например,
опциональное поле, добавленное после первых записей), `Record#initialize`
применит `default:` из декларации. Но если `nil` был явно записан — вернётся
`nil`, а не default. Разница между *отсутствующим* и *явно nil* не моделируется.
Стоит протестировать и, возможно, ввести отдельное понятие.

---

### [предстоящее] Вложенные Hash-значения

Текущий DSL не имеет вложенных типов:

```ruby
field :address  # { city: "Moscow", zip: "101000" }
```

После round-trip через igniter-ledger ключи становятся Symbols (`:city`, `:zip`).
Это правильно. Но нет способа объявить структуру вложенного объекта.
Кандидат для будущего расширения: `embedded :address do ... end`.

---

### [предстоящее] Сходимость с `examples/application/companion`

Текущий `CompanionStore` в `examples/application/companion/services/companion_store.rb`
использует blob-JSON через SQLite. Целевой путь:

```
PersistenceSketchPack (DSL: persist/history/field/scope)
  → генерирует Record/History классы
  → хранит через Igniter::DurableModel::Store
  → backed by Igniter::Ledger::LedgerStore (facts + WAL)
```

Когда первый реальный `persist :reminders` пройдёт через этот стек end-to-end,
туннели сойдутся.
