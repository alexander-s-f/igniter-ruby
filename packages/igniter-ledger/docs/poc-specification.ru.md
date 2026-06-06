# Contract-Native Store: Спецификация POC

Дата: 2026-04-29.
Область: Ruby POC, доказывающий основную модель хранения. Не публичный API.
Источник: `examples/store_poc.rb` — запускаемый, только stdlib.
Канонический: `poc-specification.md`.

---

## Что доказывает этот POC

Пять утверждений, которые должны выполняться до любых дальнейших работ:

| Утверждение | Доказано в |
|-------------|------------|
| Content-addressed факты дают дедупликацию бесплатно | Секция 8 демо |
| Time-travel структурен, не добавлен сверху | Секция 4 |
| Цепочка причинности (causation) не рвётся при записях | Секции 2 + 5 |
| Реактивная инвалидация достигает агентов без опроса | Секция 6 |
| File-backed WAL выживает после перезапуска процесса | Секция 9 |

Compile-time регистрация access paths также демонстрируется (секция 1),
но её полная ценность проявится когда компилятор будет генерировать пути
автоматически из `store_read` объявлений.

---

## Архитектура

```
   Contract DSL (store_read / store_write)
          │ register_path (при загрузке класса)
          ▼
   ┌─────────────────────────────────────────────┐
   │           IgniterStore (фасад)              │
   │                                             │
   │  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
   │  │ FactLog  │  │ReadCache │  │SchemaGraph│  │
   │  │  (WAL)   │  │(проекции)│  │ (пути)   │  │
   │  └────┬─────┘  └────┬─────┘  └────┬──────┘  │
   │       │             │              │         │
   │       │             └──────────────┘         │
   │       │         инвалидация + push            │
   └───────┼─────────────────────────────────────┘
           │ (опционально)
      FileBackend (JSON-Lines WAL)
```

**FactLog** — append-only источник правды. Никогда не мутирует.
Хранит все факты с момента запуска процесса (или с момента последнего
replay из файла).

**ReadCache** — слой проекций. Кэширует результаты current-read по ключу
`[store, key, as_of]`. Очищается при записи; push-ит сигналы инвалидации
зарегистрированным потребителям (агентам, проекциям).

**SchemaGraph** — compile-time реестр. Access paths записываются сюда при
загрузке класса контракта. Хранилище знает кто что читает до появления
любых данных.

**FileBackend** — опциональная персистентность. JSON-Lines WAL: один факт
на строку, открыт в append mode с `sync=true`. При рестарте — replay всех
строк для восстановления in-memory индексов.

---

## Основная модель данных

### Fact

```ruby
Fact = Struct.new(
  :id,             # String   — SecureRandom.uuid
  :store,          # Symbol   — какой Store[T] или History[T]
  :key,            # String   — идентичность внутри хранилища
  :value,          # Hash     — payload (глубоко заморожен)
  :value_hash,     # String   — SHA-256 stable-сериализованного value
  :causation,      # String?  — value_hash предыдущего факта для этого key
  :timestamp,      # Float    — Process.clock_gettime в момент записи
  :term,           # Integer  — Raft term (0 = standalone)
  :schema_version, # Integer  — версия схемы контракта
  keyword_init: true
)
```

**Stable serialization** сортирует ключи Hash перед хешированием. Порядок
вставки в Hash никогда не влияет на `value_hash`. Два факта с одинаковым
логическим содержимым всегда разделяют один content address.

**Causation** связывает факты в per-key связный список:

```
write key="r1" {status: :open}   → Fact f1 (causation: nil)
write key="r1" {status: :closed} → Fact f2 (causation: f1.value_hash)
```

Следуя `causation` назад от любого факта, получаем полную историю мутаций
для этого ключа без полного сканирования лога.

### AccessPath

```ruby
AccessPath = Struct.new(
  :store,      # Symbol        — имя хранилища
  :lookup,     # Symbol        — :primary_key | :scope | :filter
  :scope,      # Symbol?       — именованный scope (:open, :pending, …)
  :filter,     # Hash?         — field → привязка к input-узлу
  :cache_ttl,  # Integer?      — секунды; nil = без TTL
  :consumers,  # Array<#call>  — callable для инвалидации
  keyword_init: true
)
```

Регистрируется один раз на каждое `store_read` объявление при загрузке
класса контракта. Хранилище предварительно индексирует на основе этой
информации; в runtime путь доступа уже разрешён.

---

## Write path

```
store.write(store: :reminders, key: "r1", value: { … })

  1. Получить последний Fact для [store, key] из FactLog
  2. Fact.build: stable-serialize value → SHA-256 → causation chain
  3. FactLog.append (in-memory + опционально FileBackend.write_fact)
  4. ReadCache.invalidate(store, key)
     → удаляет текущие cache entries для этого key
     → вызывает каждого зарегистрированного consumer: agent_mailbox.call(...)
  5. Возвратить новый Fact
```

Для `History[T]` (append-only) ключ — это новый `SecureRandom.uuid` на
каждое событие. "Последней версии" нет — каждый append является корневым
фактом с `causation: nil`.

---

## Read path

### Текущее чтение

```
store.read(store: :reminders, key: "r1")

  1. ReadCache.get([store, key, nil], ttl:)  → cache hit? вернуть value
  2. FactLog.latest_for(store, key)          → сканировать @by_key, взять последний
  3. ReadCache.put([store, key, nil], fact)  → кэшировать для следующего вызова
  4. Вернуть fact.value
```

### Time-travel

```
store.time_travel(store: :reminders, key: "r1", at: t_mid)

  1. ReadCache.get([store, key, t_mid])      → вероятно miss (первый вызов)
  2. FactLog.latest_for(store, key, as_of: t_mid)
     → фильтрует @by_key до фактов где timestamp <= t_mid → берёт последний
  3. ReadCache.put([store, key, t_mid], fact) → иммутабельно; никогда не инвалидируется
  4. Вернуть fact.value
```

Time-travel результаты кэшируются под ключами `as_of: Float`. Будущие
записи их не инвалидируют — прошлое состояние не может измениться.

---

## Реактивная инвалидация

Когда `store_write` выполняется, `ReadCache.invalidate` делает два действия:

1. Удаляет current-read cache entries для `[store, key]`.
2. Вызывает каждый consumer, зарегистрированный под `store`, с `(store, key)`.

Consumer — любой объект с методом `call`: лямбда, метод, обёртка
`receive` агента. Это механизм, позволяющий `ProactiveAgent` не опрашивать:

```ruby
# При загрузке контракта:
store.register_path(AccessPath.new(
  store:     :tasks,
  lookup:    :scope,
  scope:     :pending,
  cache_ttl: 30,
  consumers: [agent.method(:on_store_invalidated)]
))

# При записи в :tasks:
# store → cache.invalidate(:tasks, key) → agent.on_store_invalidated(:tasks, key)
# Агент ре-резолвит зависимость :tasks без опроса.
```

---

## File Backend

`FileBackend` — минимальный JSON-Lines WAL. Каждая строка — один Fact,
сериализованный через `fact.to_h`. Файл открывается один раз в append
mode; `sync=true` обеспечивает durability без явных `fsync` вызовов.

**Replay** при `IgniterStore.open(path)` читает все строки и передаёт каждый
Fact в `FactLog.replay` (который обходит запись в backend, избегая
повторного добавления replay-фактов в файл).

**Известные упрощения POC:**
- Нет compaction (файл растёт бесконечно)
- JSON round-trip конвертирует symbol ключи в строки
- Нет CRC или length-prefix framing (усечённая строка = молчаливая потеря)
- Один файл; нет сегментированной ротации

Это сознательные упрощения. Rust-реализация использует бинарный
framed формат (length-prefixed MessagePack + CRC-32).

---

## Вывод демо (верифицирован)

```
1. Setup
Access paths for :reminders: 1

2. Write path
f1 hash:      efee04502dcdf4f8...
f1 causation: nil  (nil = root)
f2 hash:      9df97bfc5097b37a...
f2 causation: efee04502dcdf4f8...  (← f1.value_hash)
Chain intact: true

3. Текущее чтение
Current status: :closed

4. Time-travel
Status at t_mid:          :open     ← состояние до второй записи
Status at t_after:        :closed
Status before any write:  nil

5. Causation chain
[0] hash=efee04502dcd  causation=nil
[1] hash=9df97bfc5097  causation="efee04502dcd"

6. Реактивная инвалидация
Invalidation events: [[:reminders, "r1"], [:reminders, "r1"]]

7. История
Log entries: [:created, :closed]
Events since t_mid: [:created, :closed]

8. Дедупликация
fa.value_hash == fb.value_hash: true
Order-independent hash:          true

9. WAL replay
Written 2 facts; replayed after restart — done: true
Fact count after replay: 2
```

---

## Что POC ещё не доказывает

| Возможность | Статус | Следующий шаг |
|-------------|--------|---------------|
| Компилятор генерирует access paths | Вручную в демо | Подключить к DSL compiler |
| Distributed consensus репликация | Stub (term=0) | Использовать `Igniter::Consensus` |
| Scope / filter запросы | Не реализованы | Расширить `FactLog.facts_for` |
| Coercion схемы при чтении | Не реализован | Тред B / D из research doc |
| Авто-поддержка проекций | Не реализована | Хук incremental dataflow |
| TTL cache eviction | Реализован; не нагружен | Benchmark |
| Concurrent write safety | MonitorMixin; не stress-tested | Concurrent::Map или Ractors |

---

## Цели для переписывания (Rust / C)

Если модель докажет свою состоятельность под давлением реальных приложений,
следующие компоненты — первые кандидаты на переписывание:

**FactLog** — горячий путь. Заменить `Array + Hash` на LSM-дерево
(RocksDB-стиль) для производительности записи и memory-mapped read tier
для O(1) key lookup. Causation chain естественно ложится на LSM value log.

**FileBackend** — заменить JSON-Lines на бинарный framed формат:
4-байт length prefix + MessagePack body + CRC-32 trailer. Добавить
segment rotation и compaction проход с Bloom-filter.

**ReadCache** — заменить `Hash + MonitorMixin` на sharded `DashMap`
(Rust) или `ConcurrentHash` из concurrent-ruby. Добавить LRU eviction с
настраиваемой ёмкостью.

**SchemaGraph** — read-heavy, write-rare (заполняется только при загрузке).
Flat array `AccessPath` struct-ов, отсортированных по `store`, с binary
search — достаточно. Тривиально портируется на C.

**Content addressing** — SHA-256 уже быстрый; в Rust заменить на BLAKE3
для ~3× throughput при том же уровне безопасности.

Ruby фасад (`IgniterStore`) может остаться в Ruby как тонкая FFI-обёртка
над Rust/C dylib, сохраняя zero-dependency ограничение core гема.

---

## Ссылки

- [Contract-Native Store Research](./research/store-iterations.md)
- [Contract Persistence Organic Model](../../../docs/research/contract-persistence-organic-model.md)
- [POC исходник](../examples/store_poc.rb)
- [Канонический английский файл](./poc-specification.md)
