# Contract-Native Store: Итерации исследования

Дата: 2026-04-29.
Формат: живой исследовательский документ — каждая итерация добавляется снизу.
Область: распределённые кластеры проактивных агентов; опциональный отдельный пакет.
Канонический: `store-iterations.md`. Этот файл — русская версия.

---

## Итерация 0 — Ограничения и решения

*Зафиксировано в ходе дизайн-сессии, 2026-04-29.*

Эти ограничения определяют рамки исследования и не пересматриваются без причины.

### Целевой контекст

Уровень Igniter Application / Cluster. Основной потребитель — приложение с
децентрализованными, распределёнными, проактивными агентами. Хранилище должно
обслуживать агентов, которые:

- реагируют на изменения данных проактивно (без опроса снаружи)
- распределены по кластеру
- нуждаются в согласованном общем состоянии без накладных расходов на координацию
- должны рассуждать об историческом состоянии (что произошло до события Y?)

### Граница с внешними базами данных

Мы не запрещаем разработчику использовать его любимую БД. Предоставляем
минимальный API сопряжения; всё остальное — ответственность разработчика в
реализации промежуточного слоя. Если нативное хранилище окажется лучше на
практике — оно продаст себя само. Без принуждения.

### Приоритетные возможности

Из всех возможных направлений выбраны два:

1. **Compile-time query optimization** — пути доступа выводятся из графа
   контрактов до появления каких-либо данных, а не в runtime.
2. **Time-travel** — любое прошлое состояние доступно для запроса как
   структурное следствие иммутабельности, а не добавленная сверху фича.

### Область пакета

Опциональный, отдельный пакет (кандидат на имя: `igniter-ledger`).
Рекомендован, но не навязан. Продукт должен оправдать себя на практике.

---

## Итерация 1 — Где существующие системы не справляются

*Зафиксировано в ходе дизайн-сессии, 2026-04-29.*

Все существующие системы хранения — storage-first. Бизнес-логика живёт снаружи:

```
Relational (PG, SQLite)  → таблицы  → ORM      → бизнес-логика (снаружи)
Document (Mongo)         → документы → ODM      → бизнес-логика (снаружи)
Event stores (Kafka, ES) → события  → вручную  → бизнес-логика (снаружи)
Datomic                  → факты    → Datalog  → бизнес-логика (снаружи)
Graph DB (Neo4j)         → узлы     → Cypher   → бизнес-логика (снаружи)
```

В каждом случае движок хранения слеп к намерению. Он не знает зачем читаются
данные и что они означают в домене.

Igniter — первая система, где **полный граф зависимостей бизнес-логики известен
на compile-time**. Это открывает двери, структурно закрытые для всех систем выше.

### Три пробела, важных для распределённых агентов

**Пробел 1 — Планирование запросов в runtime.**
SQL и любой ORM строят план запроса в runtime. Движок видит запрос впервые при
его выполнении. В контракте каждый `store_read` — типизированная compile-time
зависимость. Хранилище может знать полный access pattern до появления каких-либо
данных или запросов.

**Пробел 2 — Поддержка проекций вручную.**
В CQRS/ES проекции — это написанные вручную потребители, перестраивающие read
model из событий. В Igniter проекции — это контракты. Если хранилище понимает
контракты, оно может поддерживать проекции автоматически — инкрементально,
с инвалидацией кэша из графа.

**Пробел 3 — История как второстепенная мысль.**
У Datomic есть time-travel, но это отдельный режим запросов (`as-of`,
`history`). В Igniter `History[T]` — хранилищная форма первого класса.
Append-only лог фактов — это не аудит-надстройка; это модель записи. Текущее
состояние — всегда проекция истории.

---

## Итерация 2 — Эскиз архитектуры

*Зафиксировано в ходе дизайн-сессии, 2026-04-29.*

### Синтез: контракты + time-travel + распределённые агенты

Три приоритета усиливают друг друга:

```
Compile-time граф   →  пути доступа известны на deploy
                    →  хранилище индексирует по контракту, а не по запросу
                    →  агенты объявляют reads; хранилище маршрутизирует writes

Append-only факты   →  каждая запись — новый факт, ничего не мутируется
                    →  time-travel структурен (факты где t <= T)
                    →  Raft consensus log И ЕСТЬ ось времени

Content addressing  →  факты хранятся по хешу содержимого (как Git objects)
                    →  структурное разделение между версиями бесплатно
                    →  дедупликация автоматична
                    →  цепочка причинности связывает факты (поле previous_hash)
```

### Модель факта

Каждый `store_write` производит иммутабельный факт:

```
Fact {
  contract:      ReminderContract,        # какой контракт произвёл
  store:         :reminders,              # какой Store[T]
  key:           "uuid-123",              # идентичность внутри хранилища
  value_hash:    "sha256:abc...",         # content address значения
  value:         { id: "...", ... },      # реальный payload
  causation:     "sha256:prev...",        # ссылка на предыдущий факт для этого ключа
  timestamp:     1714000000,              # wall-clock (для time-travel запросов)
  term:          42,                      # Raft term (для распределённого упорядочения)
  schema_hash:   "sha256:schema...",      # content address версии схемы
}
```

Одна структура даёт:

- **Time-travel**: `facts.select { |f| f.timestamp <= t && f.store == :reminders }`
- **Audit trail**: следовать цепочке `causation` назад
- **Версионирование схемы**: `schema_hash` связывает каждый факт с точной версией схемы
- **Распределённое упорядочение**: `term` из Raft consensus разрешает конфликты
- **Дедупликация**: одинаковое содержимое ⟹ одинаковый `value_hash`

### Генерация пути доступа на compile-time

Когда контракт объявляет:

```ruby
store_read :reminder, from: :reminders, by: :id, using: :reminder_id,
           cache_ttl: 60, coalesce: true
```

Компилятор эмитирует:

```
AccessPath {
  store:          :reminders,
  lookup:         :primary_key,
  key_binding:    :reminder_id,
  cache_strategy: :ttl,
  cache_ttl:      60,
  coalesce:       true,
  consumers:      [ReminderContract, ReminderDetailProjection, ...]
}
```

Хранилище читает это при deploy и строит индекс заранее. В runtime нет шага
"запланировать этот запрос" — путь был материализован при компиляции контракта.

### Локальность данных для распределённых агентов

Когда `ProactiveAgent` объявляет:

```ruby
store_read :pending_tasks, from: :tasks, scope: :pending, cache_ttl: 30
```

Хранилище знает на deploy:

- `ProactiveAgent` читает `:tasks` со scope `:pending`
- кэш 30 сек
- при изменении `:tasks` — цель инвалидации кэша `ProactiveAgent`
- если `ProactiveAgent` работает на Node A — реплицировать релевантные
  изменения `:tasks` на Node A с приоритетом

Это **оптимизация локальности данных, выведенная из графа контрактов** — невозможна
ни в каком ORM или планировщике запросов сегодня.

### Внутренняя структура хранилища (кандидат)

```
igniter-ledger/
  WriteStore     ← append-only лог фактов; WAL-backed; content-addressed values
  ReadStore      ← проекции, поддерживаемые графом контрактов; живые materialized views
  TimeIndex      ← индекс timestamp + term над логом фактов (O(log n) time-travel)
  SchemaGraph    ← compile-time сгенерированные пути доступа из контрактов
  ClusterSync    ← consensus репликация через существующий Igniter::Consensus (Raft)
  Adapter API    ← минимальная поверхность сопряжения для внешних БД (escape hatch)
```

### Связь с существующими компонентами Igniter

```
Igniter::Consensus  →  ClusterSync использует Raft log; записи лога = факты
Igniter::NodeCache  →  ReadStore соблюдает существующую семантику TTL + coalescing
Igniter::AI::Agent  →  ProactiveAgent может подписываться на проекции ReadStore
incremental dataflow →  поддержка проекций — это модель инкрементальных вычислений
Saga / Effect       →  сбой store_write инициирует Saga компенсацию; факт не коммитится
```

---

## Итерация 3 — Открытые треды

*Зафиксировано в ходе дизайн-сессии, 2026-04-29. Для расширения в будущих итерациях.*

### Тред A — Минимальная поверхность Adapter API

Какой минимальный интерфейс нужен разработчику для подключения внешней БД?

Кандидат:

```ruby
module Igniter::Store::Adapter
  # Вызывается store_read узлами в runtime (после резолвинга compile-time пути)
  def read(store_key, lookup)     # → Fact или nil

  # Вызывается store_write узлами на app boundary
  def write(store_key, fact)      # → committed Fact

  # Вызывается store_append узлами (History[T])
  def append(history_key, fact)   # → appended Fact

  # Вызывается compile-time path builder при deploy
  def build_access_path(path_descriptor)  # → void; реализация сохраняет индекс
end
```

Открыто: должен ли `build_access_path` быть опциональным (пропускаться для
простых адаптеров)?

### Тред B — API time-travel запросов

Как выглядит time-travel запрос из контракта?

Кандидат DSL:

```ruby
store_read :reminder_at_t, from: :reminders, by: :id, using: :reminder_id,
           as_of: :query_time   # :query_time — input узел

# Или как проекция:
project :reminder_history, from: :reminders, key: :reminder_id,
        over: :all_time         # возвращает Array<Fact>, упорядоченный по timestamp
```

Открыто: должен ли time-travel быть keyword первого класса или опцией на
`store_read`? Должен ли `as_of` принимать Raft term (для распределённой
консистентности) в дополнение к wall-clock timestamp?

### Тред C — Контракт как язык запросов

Радикальное направление: язык контрактов IS язык запросов. Никакого SQL,
GraphQL, Cypher. Контракт-запрос (read-only) объявляет зависимости `store_read`;
хранилище исполняет их как скомпилированный query plan.

```ruby
class FindPendingTasksQuery < Igniter::Contract
  define do
    input  :agent_id
    store_read :tasks, from: :tasks, scope: :pending,
               filter: { assigned_to: :agent_id }
    compute :prioritized, depends_on: [:tasks], call: PrioritySort
    output :prioritized
  end
end
```

Открыто: стоит ли развивать это в нативном хранилище или это слой над API
хранилища?

### Тред D — Эволюция схемы без миграций

Когда тип поля контракта меняется с `:string` на `:integer`, хранилище держит
факты, произведённые под обеими версиями схемы (отслеживается через
`schema_hash`). Coercion контракт может их связать:

```ruby
class ReminderContract::Coercion::V1toV2 < Igniter::Contract
  define do
    input  :fact_v1
    compute :coerced, depends_on: [:fact_v1], call: CoerceStatusField
    output :fact_v2
  end
end
```

Старые факты никогда не перезаписываются. Read path прозрачно запускает
coercion контракт когда `schema_hash` не совпадает с текущей версией.

Открыто: должны ли coercion контракты автогенерироваться из field diff
(migration plan) или всегда создаваться вручную?

### Тред E — Реактивное хранилище для проактивных агентов

Когда агент проактивный — он не должен опрашивать хранилище. Хранилище должно
push-инвалидировать агентов, чьи access paths покрывают изменившиеся факты.

```
Факт записан в :tasks (scope :pending затронут)
→ хранилище проверяет SchemaGraph: у кого AccessPath на :tasks/:pending?
→ ProactiveAgent на Node A и Node B подписаны
→ хранилище push-ит инвалидацию в mailbox обоих агентов
→ агенты ре-резолвят зависимость :tasks без опроса
```

Это сливает существующую модель mailbox `Igniter::AI::Agent` с реестром access
paths хранилища.

Открыто: push инвалидации или push нового факта? Push сначала в локальный node
cache, затем к удалённым агентам?

---

## Кандидаты следующих итераций

Порядок приоритета (открыт для пересмотра):

1. **Тред A** — закрепить минимальный adapter API; это определяет escape hatch
   и ограничивает область нативного хранилища
2. **Тред B** — определить time-travel query API; это главный дифференциатор
3. **Тред E** — реактивное хранилище + проактивные агенты; это первичный use
   case, должен определять дизайн write path
4. **Тред D** — coercion контракты / zero-migration evolution; строится на B
5. **Тред C** — контракт как язык запросов; самое радикальное, наименее срочно

---

## Итерация 4 — Тред E: дизайн Query API на контракте

*Зафиксировано в ходе дизайн-сессии, 2026-04-29.*

### Вопрос

Должен ли `ArticleContract.find(title: "hello igniter")` существовать на
классе? Рассмотрены три пути:

- **A** — Arel-style class method (`ArticleContract.find(...)`)
- **B** — `Persistable` mixin/враппер (отдельный класс как `Contractable`)
- **C** — запросы объявляются в теле контракта; никакого runtime query building

### Почему Arel-style неправильный ответ для Igniter

`ArticleContract.find(title: "hello igniter")` нарушает три инварианта Igniter:

1. **Нет compile-time валидации** — запрос строится в runtime; компилятор
   ничего о нём не знает.
2. **Store должен инжектироваться per-execution**, а не храниться как
   class-level синглтон. Глобальный `ArticleContract.store = my_store`
   нетестируем и неправильен в кластере.
3. **Контракт становится гибридом** — schema + validator + query object
   одновременно. Эти concerns не должны смешиваться.

### Почему `Persistable` — неправильный уровень абстракции

`Persistable` решает правильную проблему ("не все контракты — persistence"),
но на неправильном уровне. Opt-in — это объявление `persist` внутри тела
контракта. Контракт с `persist` получает store surface; без него — ничего.
Отдельный модуль-враппер добавляет косвенность без прибавки в ясности.

### Правильная модель: запросы — это контракты

Запрос в Igniter — это контракт с `input` узлами и `store_read`
зависимостями. Макрос `query` объявляет именованный мини-контракт,
привязанный к родительскому классу. Компилятор валидирует его при загрузке
точно так же как основной `define` блок.

```ruby
class ArticleContract < Igniter::Contract
  # Opt-in: только у этого контракта есть store surface
  persist :articles, key: :id do
    field :id,     type: Types::UUID,   default: -> { SecureRandom.uuid }
    field :title,  type: Types::String
    field :status, type: Types::Symbol, default: :draft
    index :title
    scope :by_title,  where: { title: :title }
    scope :published, where: { status: :published }
  end

  # query = объявленный store_read контракт; генерирует sugar на классе
  query :find_by_title do
    input  :title
    store_read :article, from: :articles, scope: :by_title
    output :article
  end

  query :published_articles do
    store_read :articles, from: :articles, scope: :published
    output :articles
  end

  # Time-travel — просто ещё один input, не специальный режим
  query :article_at do
    input  :id
    input  :as_of
    store_read :article, from: :articles, by: :id, using: :id, as_of: :as_of
    output :article
  end

  # Бизнес-логика — отдельно
  define do
    input :title
    input :status
    compute :validated, depends_on: %i[title status], call: ValidateArticle
    store_write :saved, from: :validated, target: :articles
    output :saved
  end
end
```

Использование — store всегда инжектируется per-call, никогда не глобальный:

```ruby
# Sugar, сгенерированный из query деклараций:
ArticleContract.find_by_title(title: "hello igniter", store: my_store)
ArticleContract.published_articles(store: my_store)
ArticleContract.article_at(id: "uuid-123", as_of: 3.days.ago.to_f, store: my_store)

# Под капотом — каждый вызов является просто выполнением контракта:
ArticleContract::Queries::FindByTitle.execute({ title: "hello igniter" }, store: my_store)
```

### Сравнение

| | Arel / ActiveRecord | Igniter `query` |
|--|-----|------|
| Валидация запроса | runtime | compile-time |
| Store scope | глобальный синглтон | per-call injection |
| Time-travel | отдельный API | `input :as_of` — обычный input |
| Реактивная инвалидация | нет | `store_read` → cache miss → agent push |
| Cache | отдельная настройка | `cache_ttl:` на `store_read` |
| Тестирование | мок ORM | `adapter: :memory` |
| "Не все контракты" | `include Persistable` | просто нет `persist` блока |

### Решение: A + B (отложено)

- **Основной путь (A)**: только объявленные `query` блоки генерируют
  class-level методы. Любое чтение должно быть задекларировано.
  Валидируется компилятором. Это целевая модель.

- **Сложные случаи (B)**: отдельный query contract без sugar, для запросов
  которые не принадлежат одному контракту:

  ```ruby
  class FindDraftsByAuthor < Igniter::Contract
    define do
      input :author_id
      store_read :drafts, from: :articles,
                 filter: { author_id: :author_id, status: :draft }
      output :drafts
    end
  end
  ```

- **Никакого Arel-style runtime query building.** Никогда.

- **Реализация макроса `query` отложена** до давления реальных приложений.
  Модель принята; sugar появится когда будет нужен.

### Ключевые инварианты, которые сохраняются

- Контракт без `persist` имеет нулевую store surface.
- Store всегда инжектируется per execution (keyword аргумент `store:`).
- Каждый запрос — скомпилированный граф; компилятор валидирует inputs,
  типы и `store_read` привязки при загрузке.
- Time-travel не требует специального режима запроса — `as_of:` —
  обычный типизированный input.

---

## Итерация 5 — Тред B: Time-Travel DSL API

*Зафиксировано в ходе дизайн-сессии, 2026-04-29.*

### Три измерения time-travel

Time-travel — это не одна семантика, а три различных формы запроса:

```
as_of:        Float | Integer  → «что было на момент T?»            — single value
since/until:                   → «все версии между T1 и T2»          — Array
after_fact:   String           → «состояние после конкретного факта» — causal
```

Форма возврата ортогональна:

```
returns: :value           → payload Hash (default)
returns: :history         → Array<Hash>, упорядоченный по timestamp
returns: :fact            → сырой Fact struct (полные метаданные, для audit)
returns: :causation_chain → [{value_hash, causation, timestamp}, ...]
```

### Решение: `as_of` — опция на `store_read`, не отдельный keyword

```ruby
# НЕ это (лишний keyword засоряет DSL):
store_read_at :article, from: :articles, at: :query_time

# А это — as_of как параметр store_read:
store_read :article, from: :articles, by: :id, using: :id, as_of: :query_time
```

`as_of:` принимает два типа из существующей type system:

- **Float** → сравнивается с `fact.timestamp` (wall-clock, standalone)
- **Integer** → сравнивается с `fact.term` (Raft term, cluster)

Store определяет режим по типу значения. Новый тип `TimePoint` не нужен
в первой итерации.

`after_fact:` принимает **String** (value\_hash) для точного каузального
упорядочивания в distributed деплоях, где wall-clock ненадёжен при clock skew.

### Полная сигнатура `store_read` с time-travel

```ruby
store_read :node_name,
  from:        :store_name,         # какой Store[T]
  by:          :primary_key,        # :primary_key | :scope | :filter
  using:       :input_node,         # input узел с ключом
  scope:       :scope_name,         # для :scope lookup
  filter:      { field: :input },   # для :filter lookup

  # time-travel
  as_of:       :time_input,         # Float (wall-clock) | Integer (Raft term)
  since:       :from_input,         # начало диапазона (auto → returns: :history)
  until:       :to_input,           # конец диапазона
  after_fact:  :hash_input,         # String — value_hash точки причинности

  # форма возврата
  returns:     :value,              # :value | :history | :fact | :causation_chain
  schema:      :current,            # :current (coerce) | :as_stored (raw, audit)

  # кэш
  cache_ttl:   60,                  # игнорируется для time-travel (прошлое иммутабельно)
  coalesce:    true
```

Правила совместимости:

| Комбинация | Результат |
|---|---|
| `as_of:` | single value на T; иммутабельно кэшируется |
| `since:` + `until:` | auto `returns: :history` |
| `after_fact:` | single value после точки причинности; иммутабельно кэшируется |
| `returns: :causation_chain` | временные ограничения игнорируются; полная цепочка |
| `as_of:` + `cache_ttl:` | `cache_ttl:` игнорируется; прошлое не меняется |

### Полный пример на ArticleContract

```ruby
class ArticleContract < Igniter::Contract
  persist :articles, key: :id do
    field :id,         type: :string
    field :title,      type: :string
    field :status,     type: :symbol, default: :draft
    field :body,       type: :string
    field :updated_at, type: :float,  default: -> { Time.now.to_f }
    index :title
    index :status
    scope :published, where: { status: :published }
  end

  # «Каким был этот Article на момент T?»
  # as_of: Float → wall-clock (standalone)
  # as_of: Integer → Raft term (cluster)
  query :article_at do
    input :id
    input :as_of   # Float | Integer — store определяет режим по типу
    store_read :article, from: :articles, by: :id, using: :id, as_of: :as_of
    output :article
  end

  # «Состояние после конкретного факта» — каузальная точность
  # Нужно в distributed: wall-clock ненадёжен при clock skew
  query :article_after_fact do
    input :id
    input :fact_hash   # String — value_hash из Fact
    store_read :article, from: :articles, by: :id, using: :id,
               after_fact: :fact_hash
    output :article
  end

  # «Все версии между T1 и T2»
  query :article_versions do
    input :id
    input :from_time, type: :float, default: -> { (Time.now - 86_400 * 30).to_f }
    input :to_time,   type: :float, default: -> { Time.now.to_f }
    store_read :versions, from: :articles, by: :id, using: :id,
               since: :from_time, until: :to_time   # auto: returns :history
    output :versions   # Array<Hash>
  end

  # «Полная цепочка мутаций» — отладка и аудит
  query :article_lineage do
    input :id
    store_read :chain, from: :articles, by: :id, using: :id,
               returns: :causation_chain
    output :chain   # [{value_hash:, causation:, timestamp:}, ...]
  end

  # «Сырой факт как сохранён» — audit без coercion схемы
  query :article_audit_snapshot do
    input :id
    input :as_of
    store_read :fact, from: :articles, by: :id, using: :id,
               as_of: :as_of, returns: :fact, schema: :as_stored
    output :fact   # Fact struct: value_hash, causation, schema_version
  end

  define do
    input :title
    input :body
    input :status
    compute :validated, depends_on: %i[title body status], call: ValidateArticle
    store_write :saved, from: :validated, target: :articles
    output :saved
  end
end
```

Использование — store всегда per-call:

```ruby
store = Igniter::Store::IgniterStore.new

# Текущее состояние
ArticleContract.execute({ title: "hello", body: "...", status: :draft }, store: store)

# Точка во времени, wall-clock
ArticleContract.article_at(id: "uuid-1", as_of: 3.days.ago.to_f, store: store)

# Точка во времени, Raft term (cluster)
ArticleContract.article_at(id: "uuid-1", as_of: 42, store: store)

# После конкретного факта (causal — самое точное)
ArticleContract.article_after_fact(id: "uuid-1", fact_hash: "sha256:abc...", store: store)

# Срез истории
ArticleContract.article_versions(id: "uuid-1",
                                  from_time: 7.days.ago.to_f,
                                  to_time:   Time.now.to_f,
                                  store: store)

# Causation chain
ArticleContract.article_lineage(id: "uuid-1", store: store)

# Audit snapshot без coercion
ArticleContract.article_audit_snapshot(id: "uuid-1", as_of: 3.days.ago.to_f, store: store)
```

### Кэш-поведение time-travel

```
as_of: nil    → current read   → кэш [store, key, nil]    → инвалидируется при записи
as_of: Float  → time-travel    → кэш [store, key, as_of]  → НИКОГДА не инвалидируется
after_fact:   → causal read    → кэш [store, key, hash]   → НИКОГДА не инвалидируется
since/until   → history slice  → НЕ кэшируется (слишком большой → используй проекции)
```

Прошлое иммутабельно. `cache_ttl:` для time-travel игнорируется;
результат кэшируется навсегда после первого разрешения.

### Отложено (не в первой итерации)

| Вопрос | Статус |
|--------|--------|
| `Types::TimePoint` (unified clock type) | Отложено — Float/Integer достаточно |
| Pagination для `:history` (`limit:`, `offset:`) | Отложено — давление приложений |
| `schema: :as_stored` coercion contracts | Отложено — связано с Тредом D |
| `since/until` кэширование через проекции | Отложено — Тред E / incremental dataflow |
| Raft log index как третий ordering primitive | Отложено — term достаточно сейчас |

---

## Итерация 6 — Тред D: Zero-Migration Schema Evolution через Coercion Contracts

*Зафиксировано в ходе дизайн-сессии, 2026-04-29.*

### Проблема

При эволюции схемы контракта хранилище содержит факты под несколькими версиями
схемы одновременно. Каждый Fact несёт `schema_version: Integer` (из POC).
Старые факты иммутабельны — никогда не перезаписываются. Read path должен
прозрачно связывать старую и новую схему.

### Классификация изменений (реиспользуется из Companion)

Классификация уже доказана в `WizardTypeSpecMigrationPlanContract`:

```ruby
def self.migration_status(added_fields, removed_fields, changed_fields)
  return :destructive if removed_fields.any?
  return :ambiguous   if changed_fields.any?
  return :additive    if added_fields.any?
  :stable
end
```

Маппинг на требования к coercion:

| Изменение | Coercion нужна | Генерируется автоматически? |
|---|---|---|
| stable (нет изменений) | нет | — |
| additive (поле добавлено) | да — inject default | **да** |
| destructive (поле удалено) | да — drop field | **да** |
| ambiguous / type change | да — трансформация | **нет** — hand-authored |
| rename (`:old` → `:new`) | да — remapping | **нет** — неоднозначно |

### `schema_version` на контракте

Объявляется явно; разработчик инкрементирует при изменении полей:

```ruby
class ArticleContract < Igniter::Contract
  schema_version 2   # инкрементирован с 1; запускает проверку пути coercion
  ...
end
```

### DSL блока `coercion`

Объявляется рядом с `persist` блоком. Только ambiguous поля требуют явных
объявлений; additive и destructive обрабатываются автоматически.

```ruby
class ArticleContract < Igniter::Contract
  schema_version 2

  persist :articles, key: :id do
    field :id,     type: :string
    field :title,  type: :string
    field :status, type: :symbol, default: :draft  # v1: был type: :string
    field :tags,   type: :array,  default: []      # v2: добавлено
    index :status
    scope :published, where: { status: :published }
  end

  # Путь: v1 → v2 (current)
  # auto: :tags (additive) → inject default []
  # hand: :status (ambiguous: string→symbol) → явная lambda
  coercion :articles, from_version: 1 do
    field :status, via: ->(v) { v.to_sym }
    # :tags — автоматически; default берётся из persist блока
  end

  # При появлении v3 — добавить coercion from_version: 2
  # Цепочка: v1 → CoercionV1toV2 → v2 → CoercionV2toV3 → v3
end
```

Под капотом каждый `coercion` блок компилируется в анонимный контракт —
в духе "всё есть контракт":

```ruby
# Что компилятор генерирует из coercion блока выше:
ArticleContract::Coercions::V1ToV2 = Igniter::Contract.define do
  input :raw_fact   # Fact struct

  compute :coerced, depends_on: [:raw_fact] do |raw_fact:|
    v = raw_fact.value.dup
    # hand-authored: status string → symbol
    v[:status] = v.fetch(:status, "draft").to_sym
    # auto-generated: tags additive, inject field default
    v[:tags]   = v.fetch(:tags, [])
    v
  end

  output :coerced
end
```

### Read path с прозрачной coercion

```
store_read :article, from: :articles, by: :id, using: :id
  ↓
1. Fetch latest Fact для [:articles, key]          — из FactLog
2. fact.schema_version == ArticleContract.schema_version?
   → да  : вернуть fact.value напрямую
   → нет : найти путь coercion в SchemaRegistry
3. Построить цепочку: v1 → V1ToV2 → v2 → V2ToV3 → v3 (current)
4. Выполнить chain (каждый шаг — pure contract execution, без side effects)
5. Кэшировать результат под [store, key, as_of, target_schema=current]
6. Вернуть coerced value

Факт в логе НИКОГДА не изменяется.
```

Cache key включает `target_schema_version` — при следующем бампе схемы
устаревший coerced результат не подаётся.

### Schema Registry

`SchemaGraph` (из POC) расширяется до `SchemaRegistry`:

```ruby
SchemaRegistry = {
  articles: {
    current_version: 2,
    versions: {
      1 => { fields: { id: :string, title: :string, status: :string } },
      2 => { fields: { id: :string, title: :string, status: :symbol, tags: :array } }
    },
    coercions: {
      [1, 2] => ArticleContract::Coercions::V1ToV2
      # [2, 3] => ... при появлении v3
    }
  }
}
```

Путь coercion — кратчайший путь от `fact.schema_version` до
`current_version`. Обычно линейная цепочка. В первой итерации — только линейная.

### Compile-time валидация

При загрузке класса контракта компилятор проверяет:

```
1. Собрать все schema_version в SchemaRegistry для :articles
2. Для каждого N < current: есть ли coercion [N, N+1]?
3. Путь отсутствует → WARN: "no coercion from v1 to v2 for :articles;
   store_read with schema: :current завершится ошибкой в runtime для v1 фактов"
4. Destructive изменение без :safe_to_drop аннотации → WARN
```

Предупреждение, не ошибка — хранилище может не содержать фактов под старой
версией (например первый деплой).

### Граничные случаи

**Rename:**

```ruby
coercion :articles, from_version: 1 do
  rename :name, to: :full_name   # явное; разработчик разрешает неоднозначность
end
```

**Destructive с подтверждением:**

```ruby
coercion :articles, from_version: 1 do
  drop :legacy_field, safe_to_drop: true
end
```

**Несовместимый тип без безопасного дефолта:**

```ruby
coercion :articles, from_version: 1 do
  field :status, via: ->(v) {
    %i[draft published archived].include?(v&.to_sym) ? v.to_sym : :draft
  }
end
```

### Принцип zero-migration

Нет migration файлов. Нет `ALTER TABLE`. Нет data backfill.

```
Разработчик меняет поля в persist блоке
→ инкрементирует schema_version
→ объявляет coercion блок для ambiguous изменений
→ деплоит

В хранилище:
  старые факты → schema_version: 1  (иммутабельны навсегда)
  новые факты  → schema_version: 2
  read path    → прозрачно coerces v1 → v2 on demand

Никакого downtime. Никаких скриптов.
```

| | ActiveRecord migration | Igniter coercion |
|---|---|---|
| Изменение схемы | migration file + ALTER TABLE | `schema_version N` + `coercion` блок |
| Старые данные | backfill или NULL default | факты в логе под старым schema_version |
| Чтение старых | прямо (уже мигрированы) | coercion chain on demand |
| Rollback | down-migration | схема иммутабельна; chain работает в обе стороны |
| Downtime | иногда (lock на большие таблицы) | нет |
| Audit | данные до миграции потеряны | исходные факты сохранены навсегда |

### Отложено

| Вопрос | Статус |
|--------|--------|
| Реализация SchemaRegistry в store | Отложено — после стабилизации query API |
| Compiler enforcement coercion paths | Отложено — требует расширения компилятора |
| Производительность coercion chain (warm-up) | Отложено — сначала benchmark |
| Cross-contract coercion (общий Store[T]) | Отложено — вне текущей области |
| `schema: :as_stored` returning raw Fact | Связано с Тредом B — уже решено |

---

## Итерация 7 — Тред E: Реактивное хранилище + Проактивные агенты

*Зафиксировано в ходе дизайн-сессии, 2026-04-29.*

### Ключевой инсайт: push trigger рядом с существующим timer trigger

`ProactiveAgent` уже работает через `_scan` механизм:
timer → `:_scan` → poll all watchers → evaluate triggers → act.

Тред E добавляет **push trigger** рядом с timer: когда хранилище записывает
факт, оно немедленно инициирует `:_scan` вместо ожидания следующего тика.
Оба пути используют один `_scan` pipeline; store push — основной сигнал,
timer — fallback надёжности.

```
Pull (существующий):
  timer(scan_interval) → :_scan → poll all watchers → evaluate triggers → act

Push (новый):
  store.write → ReadCache.invalidate → consumer.call →
  → agent mailbox ← :_scan → poll store-backed watchers → evaluate triggers → act
```

### Новая форма `watch` для store-backed зависимостей

```ruby
# Существующая форма (poll lambda):
watch :pending_tasks, poll: -> { external_api.fetch_tasks }

# Новая форма (store-backed, reactive):
watch :pending_tasks, store: :tasks, scope: :pending, cache_ttl: 30
```

При старте агента store-backed watch регистрирует AccessPath с
`consumers: [method(:trigger_scan)]`. `trigger_scan` кладёт `:_scan` в
mailbox агента немедленно:

```ruby
def trigger_scan(store, key)
  mailbox.send(:_scan, { source: :store_push, store: store, key: key })
end
```

Poll lambda для store-backed watch генерируется автоматически:

```ruby
# Компилируется из watch :pending_tasks, store: :tasks, scope: :pending:
watch :pending_tasks, poll: -> { @store.read(store: :tasks, scope: :pending) }
```

Scan loop агента не меняется — всегда вызывает poll lambdas. Отличие только
в том **кто инициирует** scan: timer или store.

### Полный пример: TaskDispatcherAgent

```ruby
class TaskDispatcherAgent < Igniter::Server::Agents::ProactiveAgent
  intent "Dispatch pending tasks as soon as they appear in the store"

  # Store-backed watch — push model
  # Любая запись в :tasks инициирует немедленный scan
  watch :pending_tasks, store: :tasks, scope: :pending, cache_ttl: 30

  # Обычный poll watch — без изменений
  watch :agent_config, poll: -> { Config.current }

  trigger :new_pending_tasks,
          condition: ->(ctx) {
            ctx[:pending_tasks]&.any? { |t| t[:dispatched_at].nil? }
          },
          action: ->(state:, context:) {
            undispatched = context[:pending_tasks].reject { |t| t[:dispatched_at] }
            undispatched.each { |task| dispatch(task) }
            state.merge(last_dispatch_count: undispatched.length)
          }

  # Длинный fallback интервал — store push основной механизм
  scan_interval 60.0

  private

  def dispatch(task) = ...
end

agent = TaskDispatcherAgent.start(store: my_store)
```

### Контрактный уровень: `store_read reactive: true` и `tick`

Для агентов, которые используют контракт как scan-логику:

```ruby
class PendingTasksContract < Igniter::Contract
  define do
    # reactive: true — при изменении :tasks/:pending уведомить потребителя
    store_read :tasks, from: :tasks, scope: :pending,
               cache_ttl: 30, reactive: true

    compute :prioritized, depends_on: [:tasks], call: PrioritizeByDeadline
    output :prioritized
  end
end

class TaskDispatcherAgent < Igniter::Server::Agents::ProactiveAgent
  # tick = контракт является scan-логикой агента
  # Агент перевыполняет контракт при reactive инвалидации
  tick PendingTasksContract, store: :companion_store

  on :tick_result do |result|
    next unless result.success?
    result[:prioritized].each { |task| schedule_work(task) }
  end

  scan_interval 120.0  # очень длинный fallback; store push основной
end
```

`tick` компилируется в:
1. `watch :_tick_result, poll: -> { PendingTasksContract.execute({}, store: @store) }`
2. Все `store_read reactive: true` в контракте регистрируют consumers.
3. Trigger отправляет `:tick_result` при изменении результата.

### Полный flow: store write → agent action

```
1. store.write(store: :tasks, key: "t1", value: { status: :pending, ... })

2. FactLog.append(fact)

3. ReadCache.invalidate(store: :tasks, key: "t1")
   → удалить cache entries для :tasks/"t1"
   → consumers для :tasks: [TaskDispatcherAgent(A).trigger_scan,
                              TaskDispatcherAgent(B).trigger_scan]

4. TaskDispatcherAgent(A).trigger_scan(:tasks, "t1")
   → mailbox.send(:_scan, { source: :store_push, store: :tasks, key: "t1" })

5. Agent thread: _scan handler fires
   → poll :pending_tasks (store.read :tasks, scope: :pending)
   → store: cache miss (только что инвалидирован)
   → FactLog: latest fact + scope filter → [{ id: "t1", status: :pending, ... }]

6. Evaluate trigger :new_pending_tasks
   → condition: undispatched.any? → true

7. Action: dispatch(task)
   → state.merge(last_dispatch_count: 1)
```

### Распределённый кластер: Raft + реактивность

```
Node C: store.write(:tasks, "t1", {...})
  → Raft: proposal → consensus → committed (term: 43, index: 156)

Node A: Raft log replay fact(term: 43, index: 156)
  → FactLog.append → ReadCache.invalidate → TaskDispatcherAgent(A).trigger_scan

Node B: Raft log replay fact(term: 43, index: 156)
  → FactLog.append → ReadCache.invalidate → TaskDispatcherAgent(B).trigger_scan
```

Реактивность на каждой ноде — прямое следствие Raft replay.
Никакой отдельной pub/sub инфраструктуры не нужно.

### Push что: инвалидация vs факт

| | Push invalidation | Push fact |
|---|---|---|
| Сложность | простая (уже в POC) | требует schema coercion per consumer |
| Latency | +1 re-fetch | нет re-fetch |
| Data volume | минимальный (store, key) | полный payload |
| Schema safety | агент читает в своей схеме | store должен знать схему агента |
| Первая итерация | **да** | отложено |

Решение: **push invalidation** — `consumer.call(store, key)`. Агент
перечитывает через `store_read` и может попасть в cache если другой агент
уже прочитал новое значение.

### Scope-aware filtering (отложено)

Первая итерация: любая запись в `:tasks` уведомляет ВСЕ consumers для
`:tasks` независимо от scope. Агент перечитывает и обрабатывает корректно
(большинство triggers найдут ничего не изменилось если нужный scope не затронут).

Будущее: хранилище evaluates scope condition при записи:

```ruby
if scope_condition_touched?(fact, path.scope)
  path.consumers.each { |c| c.call(fact.store, fact.key) }
end
```

Требует: store умеет evaluать scope predicates. Отложено.

### Отложено

| Вопрос | Статус |
|--------|--------|
| Реализация макроса `tick` | Отложено — модель принята; sugar под давлением |
| `reactive: true` в компиляторе | Отложено — требует расширения компилятора |
| Scope-aware consumer filtering | Отложено — первая итерация: любая запись = все уведомляются |
| Push fact (не инвалидация) | Отложено — после стабилизации schema coercion |
| Backpressure на mailbox при высоком write rate | Отложено — сначала benchmark |
| Дерегистрация consumer при остановке агента | Нужно — предотвращает memory leaks; отложено до impl |

---

## Ссылки

- [Contract Persistence Organic Model](../../../../docs/research/contract-persistence-organic-model.md)
- [Contract Persistence Roadmap](../../../../docs/research/contract-persistence-roadmap.md)
- [Companion Current Status Summary](../../../../packages/igniter-companion/docs/current-status.md)
- [POC Спецификация](../poc-specification.md)
- [Канонический английский файл](./store-iterations.md)
