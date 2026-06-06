# Contract-Native Store: Хаб Синхронизации и Управление Хранением

Дата: 2026-04-30.
Формат: живой исследовательский документ — каждая итерация добавляется ниже.
Область: PostgreSQL как хаб синхронизации, политики хранения, горячий/холодный контур.
Канонический: `sync-hub-iterations.md`. Данный файл — русский компаньон.

---

## Итерация 0 — Две Исследованные Идеи

*Зафиксировано по результатам сессии проектирования, 2026-04-30.*

До прихода к модели хаба были рассмотрены две идеи. Краткая запись:

### Идея A: Расширение PostgreSQL

Три уровня амбиций:

- **Уровень A — DDL-генератор** (на стороне Ruby): читает блок `persist` → генерирует
  SQL `CREATE TABLE`. Прагматично, расширение нативного движка не нужно.
- **Уровень B — Реактивный мост** (C/Rust `pgrx`): добавляет триггерную функцию `NOTIFY`,
  SQL-функцию `igniter_time_travel()`, оператор causation chain.
- **Уровень C — Выполнение контрактов внутри PostgreSQL**: контракты компилируются в
  хранимые процедуры. Оценено как over-engineering на данном этапе.

Решение: уровни A+B дают реальную ценность. Уровень C отложен на неопределённый срок.

### Идея B: Горячий/холодный контур

```
IgniterStore (горячий)  →  BackgroundSync  →  PostgreSQL (холодный)
in-memory + Raft            асинхронно,         долговечный, доступен
                            пакетами            для запросов
```

Write path никогда не блокируется на PostgreSQL. BackgroundSync асинхронен.
PostgreSQL выполняет роли: долговечный бэкап, аналитика, начальная загрузка (bootstrap)
для новых кластеров.

---

## Итерация 1 — Уточнённое Видение: PostgreSQL как Хаб Синхронизации

*Зафиксировано по результатам сессии проектирования, 2026-04-30.*

### Уточнение от пользователя

PostgreSQL сначала как **система резервного копирования и сидирования** — не территория
глубоких расширений. Одна простая полиморфная таблица (`igniter_facts`), в которую
поступают факты от всех кластеров. Кластеры забирают то, что им нужно. PostgreSQL
становится хабом синхронизации всех со всеми.

### Модель хаба

```
Кластер A                   Хаб PostgreSQL               Кластер B
  IgniterStore                 igniter_facts               IgniterStore
  (горячий, Raft)              (холодный, JSONB)           (горячий, Raft)
       │                            │                            │
       │ BackgroundSync             │         BackgroundSync     │
       │ push (async)               │         pull (poll/LISTEN) │
       └──────────────────────────→ │ ←────────────────────────── ┘
                                    │
                             Кластеры C, D, … тянут по той же схеме
```

Согласованность внутри кластера: Raft (строгая, быстрая).
Синхронизация между кластерами: хаб PostgreSQL (асинхронная, eventual).

### Таблица хаба — полиморфная, одна таблица для всех хранилищ

```sql
CREATE TABLE igniter_facts (
  id             UUID    NOT NULL,
  store          TEXT    NOT NULL,   -- имя Store[T] или History[T]
  key            TEXT    NOT NULL,   -- идентичность внутри хранилища
  value          JSONB   NOT NULL,   -- полезная нагрузка
  value_hash     TEXT    NOT NULL,   -- SHA-256 content address (ключ дедупликации)
  causation      TEXT,               -- value_hash предыдущего факта (цепочка)
  timestamp      FLOAT8  NOT NULL,   -- wall-clock на момент записи
  term           INTEGER NOT NULL DEFAULT 0,   -- Raft term
  schema_version INTEGER NOT NULL DEFAULT 1,
  cluster_id     TEXT    NOT NULL,   -- какой кластер создал факт
  synced_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  retain_until   TIMESTAMPTZ,        -- NULL = хранить вечно; устанавливает BackgroundSync
  PRIMARY KEY (id, synced_at)        -- составной PK для секционирования по времени
) PARTITION BY RANGE (synced_at);

-- Секции по месяцам (создаются автоматически BackgroundSync или pg_partman)
CREATE TABLE igniter_facts_2026_04
  PARTITION OF igniter_facts
  FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');

-- Основные индексы
CREATE INDEX ON igniter_facts (store, key, timestamp DESC);
CREATE UNIQUE INDEX ON igniter_facts (value_hash);   -- content-addressed дедупликация
CREATE INDEX ON igniter_facts (cluster_id, store, synced_at);
CREATE INDEX ON igniter_facts (retain_until)
  WHERE retain_until IS NOT NULL;                    -- индекс для TTL-очистки
```

**Почему полиморфная (одна таблица)?**
- Просто: изменений схемы не требуется при добавлении нового Store[T] в контракт
- Простые кросс-стор запросы: `SELECT * FROM igniter_facts WHERE timestamp > X`
- Хаб не знает и не заботится о семантике контракта — он просто хранит факты
- `value` — JSONB: любая полезная нагрузка, любая версия схемы

**Дедупликация через `value_hash`:** одинаковое содержимое от двух кластеров
попадает в хаб один раз. `ON CONFLICT (value_hash) DO NOTHING` делает push идемпотентным.

### Pull кластера: избирательная подписка

Каждый кластер объявляет, что ему нужно из хаба:

```ruby
IgniterStoreBackgroundSync.configure do |c|
  c.hub_url "postgres://hub-host/igniter_hub"

  # Пушить всё, что производит этот кластер
  c.push :all

  # Тянуть только хранилища, которые нужны кластеру
  c.pull :articles                                     # все статьи
  c.pull :tasks, scope: :pending                       # только ожидающие задачи
  c.pull :sensor_readings, from_cluster: "eu-west-1"  # только из конкретного кластера

  # Игнорировать высокообъёмные хранилища других кластеров
  c.ignore :agent_signals, from_clusters: :others
end
```

### Реактивный pull через LISTEN/NOTIFY

```sql
CREATE FUNCTION igniter_hub_notify() RETURNS trigger AS $$
BEGIN
  PERFORM pg_notify(
    'igniter_hub',
    json_build_object(
      'store',      NEW.store,
      'key',        NEW.key,
      'cluster_id', NEW.cluster_id
    )::text
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER igniter_facts_notify
  AFTER INSERT ON igniter_facts
  FOR EACH ROW EXECUTE FUNCTION igniter_hub_notify();
```

Ruby-сторона — кластер B подписывается:

```ruby
hub.listen("igniter_hub") do |notification|
  meta = JSON.parse(notification.extra, symbolize_names: true)
  next unless local_store.subscribed?(meta[:store].to_sym)
  next if meta[:cluster_id] == local_cluster_id   # пропустить собственные факты

  fact = hub.fetch_fact(meta[:store], meta[:key])
  local_store.log.replay(fact) if fact
end
```

---

## Итерация 2 — Политики Хранения

*Зафиксировано по результатам сессии проектирования, 2026-04-30.*

### Проблема: не все факты одинаковы

Некоторые факты должны храниться вечно:
- Бизнес-записи (`Store[:articles]`, `Store[:contracts]`)
- События аудита (`History[:materializer_approvals]`)
- История изменений схемы (`History[:contract_spec_changes]`)

Другие — высокообъёмные и транзиентные:
- Показания датчиков (`History[:sensor_readings]`)
- Сигналы агентов (`History[:agent_signals]`)
- Пинги health check (`History[:node_pings]`)

Без политик хранения хаб растёт безгранично. Необходим механизм очистки.

### Хранение объявляется в контракте

Хранение co-located с объявлением хранилища — два уровня:

```ruby
class SensorContract < Igniter::Contract
  history :sensor_readings, partition_key: :sensor_id do
    # hot: как долго хранить в IgniterStore (in-memory / локальный WAL)
    # cold: как долго хранить в хабе PostgreSQL
    retention hot: 1.hour, cold: 7.days

    field :sensor_id,   type: :string
    field :value,       type: :float
    field :recorded_at, type: :float
  end

  history :agent_signals, partition_key: :agent_id do
    retention hot: 15.minutes, cold: 24.hours
    field :agent_id, type: :string
    field :signal,   type: :symbol
  end

  persist :calibration, key: :sensor_id do
    retention hot: :forever, cold: :forever   # по умолчанию; явно для ясности
    field :sensor_id,   type: :string
    field :calibration, type: :float
  end
end
```

`BackgroundSync` читает метаданные хранения из манифеста контракта и устанавливает
`retain_until = NOW() + cold_ttl` при пуше фактов в хаб.

### Три стратегии очистки

**Стратегия 1 — Удаление секции** (нулевые накладные расходы при записи, для высокообъёмных транзиентных)

```sql
-- Удалить всю секцию за месяц, когда все факты в ней истекли
DROP TABLE IF EXISTS igniter_facts_2026_01;
```

Лучше для: `History[:sensor_readings]`, `History[:agent_signals]`.
Работает, когда вся секция вышла за пределы retention. Обрабатывается планировщиком
(pg_cron или встроенным sweeper в BackgroundSync).

**Стратегия 2 — Построчный TTL** (избирательно, для смешанных хранилищ)

```sql
-- Ночной sweeper:
DELETE FROM igniter_facts
WHERE retain_until IS NOT NULL
  AND retain_until < NOW();
```

Лучше для: хранилищ, где часть фактов важна, а часть транзиентна.
`retain_until` устанавливается на уровне каждого факта BackgroundSync на основе политики
хранения.

**Стратегия 3 — Компакция** (сохранить текущее состояние, удалить историю)

Для `Store[T]` (изменяемые записи), где важна только последняя версия:
хранить последний факт на ключ, удалять более старые версии старше порога.

```sql
-- Хранить только последний факт на (store, key); удалять остальные старше N дней
DELETE FROM igniter_facts f
WHERE f.store = 'sensor_calibration'
  AND f.timestamp < (NOW() - INTERVAL '30 days')::FLOAT8
  AND f.id NOT IN (
    SELECT DISTINCT ON (store, key) id
    FROM igniter_facts
    WHERE store = 'sensor_calibration'
    ORDER BY store, key, timestamp DESC
  );
```

Лучше для: хранилищ конфигурации, хранилищ последнего известного значения.

### Выбор стратегии по типу хранилища

| Тип хранилища | Стратегия по умолчанию | Обоснование |
|---|---|---|
| `persist` (изменяемый) | компакция | как правило важно только текущее состояние |
| `history` с `retention: :forever` | нет | хранить всё |
| `history` с коротким TTL | удаление секции или построчный TTL | объём определяет выбор |
| истории аудита / согласований | нет | требование compliance/legal |

### Очистка горячего контура: WAL IgniterStore

При объявлении `retention hot: 1.hour`:

- FactLog хранит скользящее окно: факты старше `hot_ttl` подлежат вытеснению
  из in-memory индекса и локального WAL файла.
- Факты, уже синхронизированные с хабом, вытесняются первыми.
- Факты, ещё не синхронизированные, удерживаются до подтверждения push от `BackgroundSync`.

```
hot_retention sweep (периодически):
  для каждого факта в FactLog:
    если fact.timestamp < (now - hot_ttl)
      И факт подтверждён синхронизированным с хабом:
        вытеснить из индекса @by_key
        пометить как вытесненный в WAL (не удалять строку WAL — только-добавление)
```

### Безопасность цепочки причинности

Факт не должен удаляться из хаба, если он является ссылкой `causation` для
удерживаемого факта. Иначе цепочки причинности станут разорванными.

Первая итерация: **игнорировать безопасность causation при очистке** — задокументировать
как известное ограничение. Цепочки причинности могут содержать пробелы после очистки.

В будущем: проход в стиле GC, который маркирует все удерживаемые факты, идёт по
цепочкам причинности назад и маркирует достижимых предков как тоже удерживаемых перед
удалением.

---

## Итерация 3 — Открытые Вопросы

*Зафиксировано по результатам сессии проектирования, 2026-04-30.*

### Q1 — Разрешение конфликтов между кластерами

Два кластера записывают разные значения для одного `(store, key)` в одном
временном окне. Оба факта поступают в хаб. Какой побеждает, когда кластер B тянет?

Варианты:
- **Last-writer-wins по timestamp** — просто; ненадёжно при расхождении часов.
- **Last-writer-wins по Raft term** — надёжно внутри кластера; пространства term
  между кластерами независимы (term=42 на A ≠ term=42 на B).
- **Явный merge contract** — объявленный контракт, разрешающий конфликты семантически
  на уровне каждого хранилища. Наиболее корректно; наиболее сложно.
- **Append-only конфликт** — для `History[T]` оба факта сохраняются (оба являются
  событиями). Для `Store[T]` (изменяемого) конфликт фиксируется и требует явного
  разрешения.

Первая итерация: last-writer-wins по timestamp для `Store[T]`;
оба факта сохраняются для `History[T]`.

### Q2 — Планирование ёмкости хаба

Высокообъёмные хранилища с коротким retention (датчики, сигналы) всё равно создают
нагрузку на запись в хаб в течение retention window.

Варианты митигации:
- Отдельные таблицы хаба по уровням retention (hot-tier: 24ч, warm-tier: 30д,
  cold-tier: навсегда) — устраняет межуровневое давление на секции.
- Семплирование: пушить только каждый N-й факт для хранилищ датчиков в хаб.
- Агрегация в BackgroundSync: вместо индивидуальных фактов датчиков пушить
  почасовые сводные агрегаты.

Первая итерация: без митигации. Добавить при наблюдении нагрузки на запись.

### Q3 — Порядок при начальной загрузке (bootstrap)

Когда новый кластер восстанавливается из хаба, он воспроизводит факты в порядке
`timestamp`. Если `timestamp` ненадёжен (расхождение часов), порядок воспроизведения
может быть неверным.

Митигация: воспроизводить по `(term, synced_at)` — `synced_at` назначается хабом
и монотонен внутри секции. Это даёт хаб-авторитетный порядок для bootstrap.

### Q4 — Расширение PostgreSQL (отложено)

DDL-генератор (уровень A) и реактивный триггер NOTIFY (уровень B) остаются в
рассмотрении для будущего пакета `igniter-hub`. Вне области охвата до стабилизации
модели хаба.

---

## Следующие Шаги

Приоритет:

1. Доказать полиморфную таблицу хаба минимальным BackgroundSync на Ruby
   (расширить `examples/igniter_store_poc.rb` или создать `examples/igniter_hub_poc.rb`)
2. Определиться с разрешением конфликтов для `Store[T]` (Q1)
3. Реализовать объявления политик хранения в DSL `persist`/`history`
4. Реализовать sweeper удаления секций для высокообъёмных транзиентных историй

---

## Ссылки

- [Contract-Native Store Research](./store-iterations.md)
- [Contract-Native Store POC](../poc-specification.md)
- [Исходник POC](../../../../examples/igniter_store_poc.rb)
- [Канонический английский файл](./sync-hub-iterations.md)
