# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Store::IgniterStore do
  it "writes immutable facts, reads current state, and preserves causation" do
    store = described_class.new

    first  = store.write(store: :reminders, key: "r1", value: { title: "Buy milk", status: :open })
    second = store.write(store: :reminders, key: "r1", value: { title: "Buy milk", status: :closed })

    expect(second.causation).to eq(first.id)
    expect(second.causation).not_to eq(first.value_hash)
    expect(store.read(store: :reminders, key: "r1")).to include(status: :closed)
    expect(store.causation_chain(store: :reminders, key: "r1").length).to eq(2)
  end

  it "causation chain is unambiguous when the same value is written twice" do
    store = described_class.new

    f1 = store.write(store: :items, key: "x", value: { status: :open })
    f2 = store.write(store: :items, key: "x", value: { status: :open })
    f3 = store.write(store: :items, key: "x", value: { status: :open })

    expect(f1.value_hash).to eq(f2.value_hash).and eq(f3.value_hash)
    expect(f2.causation).to eq(f1.id)
    expect(f3.causation).to eq(f2.id)

    chain = store.causation_chain(store: :items, key: "x")
    expect(chain.length).to eq(3)
    expect(chain[0][:causation]).to be_nil
    expect(chain[1][:causation]).to eq(f1.id)
    expect(chain[2][:causation]).to eq(f2.id)
    expect(chain.map { |e| e[:id] }).to eq([f1.id, f2.id, f3.id])
  end

  it "supports time-travel reads" do
    store = described_class.new

    store.write(store: :reminders, key: "r1", value: { status: :open })
    sleep 0.01
    middle = Process.clock_gettime(Process::CLOCK_REALTIME)
    sleep 0.01
    store.write(store: :reminders, key: "r1", value: { status: :closed })

    expect(store.time_travel(store: :reminders, key: "r1", at: middle)).to include(status: :open)
    expect(store.read(store: :reminders, key: "r1")).to include(status: :closed)
  end

  it "registers access paths and pushes invalidation signals" do
    store = described_class.new
    invalidations = []

    store.register_path(
      Igniter::Store::AccessPath.new(
        store: :reminders,
        lookup: :primary_key,
        scope: nil,
        filters: nil,
        cache_ttl: 60,
        consumers: [->(store_name, key) { invalidations << [store_name, key] }]
      )
    )

    store.write(store: :reminders, key: "r1", value: { status: :open })
    store.write(store: :reminders, key: "r1", value: { status: :closed })

    expect(store.schema_graph.paths_for(:reminders).length).to eq(1)
    expect(invalidations).to eq([[:reminders, "r1"], [:reminders, "r1"]])
  end

  it "stores append-only history facts" do
    store = described_class.new

    store.append(history: :reminder_logs, event: { action: :created })
    store.append(history: :reminder_logs, event: { action: :closed })

    expect(store.history(store: :reminder_logs).map { |fact| fact.value.fetch(:action) }).to eq(%i[created closed])
  end

  describe "#query" do
    let(:store) { described_class.new }

    before do
      store.register_path(
        Igniter::Store::AccessPath.new(
          store: :tasks,
          lookup: :primary_key,
          scope: :pending,
          filters: { status: :pending },
          cache_ttl: nil,
          consumers: []
        )
      )
      store.register_path(
        Igniter::Store::AccessPath.new(
          store: :tasks,
          lookup: :primary_key,
          scope: :done,
          filters: { status: :done },
          cache_ttl: nil,
          consumers: []
        )
      )
    end

    it "returns facts matching the scope filters" do
      store.write(store: :tasks, key: "t1", value: { title: "A", status: :pending })
      store.write(store: :tasks, key: "t2", value: { title: "B", status: :done })
      store.write(store: :tasks, key: "t3", value: { title: "C", status: :pending })

      results = store.query(store: :tasks, scope: :pending)
      expect(results.map { |f| f.value[:title] }.sort).to eq(%w[A C])
    end

    it "reflects state after updates" do
      store.write(store: :tasks, key: "t1", value: { title: "A", status: :pending })
      store.write(store: :tasks, key: "t1", value: { title: "A", status: :done })

      pending_results = store.query(store: :tasks, scope: :pending)
      done_results    = store.query(store: :tasks, scope: :done)

      expect(pending_results).to be_empty
      expect(done_results.map { |f| f.value[:title] }).to eq(["A"])
    end

    it "invalidates scope cache on write" do
      store.write(store: :tasks, key: "t1", value: { title: "A", status: :pending })
      first_query = store.query(store: :tasks, scope: :pending)
      expect(first_query.length).to eq(1)

      store.write(store: :tasks, key: "t2", value: { title: "B", status: :pending })
      second_query = store.query(store: :tasks, scope: :pending)
      expect(second_query.length).to eq(2)
    end

    it "raises ArgumentError for unknown scope" do
      expect { store.query(store: :tasks, scope: :unknown) }
        .to raise_error(ArgumentError, /scope=:unknown/)
    end

    it "applies cache_ttl from registered AccessPath automatically" do
      store_with_ttl = described_class.new
      store_with_ttl.register_path(
        Igniter::Store::AccessPath.new(
          store: :items,
          lookup: :primary_key,
          scope: :active,
          filters: { active: true },
          cache_ttl: 60,
          consumers: []
        )
      )
      store_with_ttl.write(store: :items, key: "i1", value: { active: true })
      first  = store_with_ttl.query(store: :items, scope: :active)
      second = store_with_ttl.query(store: :items, scope: :active)
      expect(first).to equal(second)
    end

    it "supports time-travel via as_of" do
      store.write(store: :tasks, key: "t1", value: { title: "A", status: :pending })
      sleep 0.01
      checkpoint = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.01
      store.write(store: :tasks, key: "t1", value: { title: "A", status: :done })

      at_checkpoint = store.query(store: :tasks, scope: :pending, as_of: checkpoint)
      expect(at_checkpoint.map { |f| f.value[:title] }).to eq(["A"])

      now = store.query(store: :tasks, scope: :pending)
      expect(now).to be_empty
    end
  end

  describe "reactive scope consumers" do
    it "notifies scope consumers when a fact in the store changes" do
      store = described_class.new
      notifications = []

      store.register_path(
        Igniter::Store::AccessPath.new(
          store: :tasks,
          lookup: :primary_key,
          scope: :pending,
          filters: { status: :pending },
          cache_ttl: nil,
          consumers: [->(s, scope) { notifications << [s, scope] }]
        )
      )

      store.write(store: :tasks, key: "t1", value: { status: :pending })
      # cache is cold — no scope entry yet, no notification
      expect(notifications).to be_empty

      # warm the cache with a query
      store.query(store: :tasks, scope: :pending)

      # second write invalidates the scope cache → notifies consumer
      store.write(store: :tasks, key: "t1", value: { status: :done })
      expect(notifications).to eq([[:tasks, :pending]])
    end

    it "notifies only scope consumers for the matching store" do
      store = described_class.new
      pending_calls = []
      done_calls    = []

      store.register_path(
        Igniter::Store::AccessPath.new(
          store: :tasks,
          lookup: :primary_key,
          scope: :pending,
          filters: { status: :pending },
          cache_ttl: nil,
          consumers: [->(s, sc) { pending_calls << sc }]
        )
      )
      store.register_path(
        Igniter::Store::AccessPath.new(
          store: :tasks,
          lookup: :primary_key,
          scope: :done,
          filters: { status: :done },
          cache_ttl: nil,
          consumers: [->(s, sc) { done_calls << sc }]
        )
      )

      store.write(store: :tasks, key: "t1", value: { status: :pending })
      # warm both scopes
      store.query(store: :tasks, scope: :pending)
      store.query(store: :tasks, scope: :done)
      pending_calls.clear
      done_calls.clear

      store.write(store: :tasks, key: "t1", value: { status: :done })

      # both scope caches were invalidated — both consumers notified
      expect(pending_calls).to eq([:pending])
      expect(done_calls).to eq([:done])
    end

    it "does not notify scope consumers for a different store" do
      store = described_class.new
      calls = []

      store.register_path(
        Igniter::Store::AccessPath.new(
          store: :tasks,
          lookup: :primary_key,
          scope: :pending,
          filters: { status: :pending },
          cache_ttl: nil,
          consumers: [->(s, sc) { calls << s }]
        )
      )

      # warm tasks scope
      store.query(store: :tasks, scope: :pending)
      calls.clear

      # write to a different store — should NOT trigger tasks scope consumer
      store.write(store: :other, key: "x1", value: { status: :pending })
      expect(calls).to be_empty
    end

    it "does not notify point-read consumers for scope paths" do
      store = described_class.new
      point_calls = []
      scope_calls = []

      store.register_path(
        Igniter::Store::AccessPath.new(
          store: :tasks,
          lookup: :primary_key,
          scope: nil,
          filters: nil,
          cache_ttl: nil,
          consumers: [->(s, k) { point_calls << k }]
        )
      )
      store.register_path(
        Igniter::Store::AccessPath.new(
          store: :tasks,
          lookup: :primary_key,
          scope: :pending,
          filters: { status: :pending },
          cache_ttl: nil,
          consumers: [->(s, sc) { scope_calls << sc }]
        )
      )

      store.write(store: :tasks, key: "t1", value: { status: :pending })
      # warm scope cache
      store.query(store: :tasks, scope: :pending)
      point_calls.clear
      scope_calls.clear

      store.write(store: :tasks, key: "t1", value: { status: :done })

      expect(point_calls).to eq(["t1"])     # point consumer fires for key
      expect(scope_calls).to eq([:pending]) # scope consumer fires for scope
    end
  end

  describe "materialized scope index" do
    let(:store) { described_class.new }

    before do
      store.register_path(
        Igniter::Store::AccessPath.new(
          store: :tasks, lookup: :primary_key, scope: :pending,
          filters: { status: :pending }, cache_ttl: nil, consumers: []
        )
      )
      store.register_path(
        Igniter::Store::AccessPath.new(
          store: :tasks, lookup: :primary_key, scope: :done,
          filters: { status: :done }, cache_ttl: nil, consumers: []
        )
      )
    end

    it "returns the same results as a full scan before and after index initialisation" do
      store.write(store: :tasks, key: "t1", value: { status: :pending })
      store.write(store: :tasks, key: "t2", value: { status: :done })
      store.write(store: :tasks, key: "t3", value: { status: :pending })

      # First query — full scan, builds index
      first = store.query(store: :tasks, scope: :pending).map { |f| f.key }.sort
      expect(first).to eq(%w[t1 t3])

      # Subsequent query — served from index
      second = store.query(store: :tasks, scope: :pending).map { |f| f.key }.sort
      expect(second).to eq(%w[t1 t3])
    end

    it "maintains the index when a key enters a scope" do
      store.query(store: :tasks, scope: :pending)  # warm index (empty)

      store.write(store: :tasks, key: "t1", value: { status: :pending })
      results = store.query(store: :tasks, scope: :pending)
      expect(results.map { |f| f.key }).to eq(["t1"])
    end

    it "maintains the index when a key leaves a scope" do
      store.write(store: :tasks, key: "t1", value: { status: :pending })
      store.query(store: :tasks, scope: :pending)  # warm: index = {t1}

      store.write(store: :tasks, key: "t1", value: { status: :done })
      expect(store.query(store: :tasks, scope: :pending)).to be_empty
      expect(store.query(store: :tasks, scope: :done).map { |f| f.key }).to eq(["t1"])
    end

    it "does not use the index for time-travel queries" do
      store.write(store: :tasks, key: "t1", value: { status: :pending })
      sleep 0.01
      checkpoint = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.01
      store.write(store: :tasks, key: "t1", value: { status: :done })

      store.query(store: :tasks, scope: :pending)  # warm index (reflects current: empty)

      # Time-travel should still see t1 as pending at checkpoint
      past = store.query(store: :tasks, scope: :pending, as_of: checkpoint)
      expect(past.map { |f| f.key }).to eq(["t1"])
    end
  end

  describe "schema coercion hook" do
    it "applies coercion on point read" do
      store = described_class.new
      store.register_coercion(:items) { |v, _sv| v.merge(coerced: true) }

      store.write(store: :items, key: "i1", value: { name: "Widget" })
      result = store.read(store: :items, key: "i1")

      expect(result).to include(name: "Widget", coerced: true)
    end

    it "passes schema_version to the coercion block" do
      store    = described_class.new
      received = []
      store.register_coercion(:items) { |v, sv| received << sv; v }

      store.write(store: :items, key: "i1", value: { x: 1 }, schema_version: 3)
      store.read(store: :items, key: "i1")

      expect(received).to eq([3])
    end

    it "applies coercion on time-travel read" do
      store = described_class.new
      store.register_coercion(:items) { |v, _sv| v.merge(migrated: true) }

      store.write(store: :items, key: "i1", value: { x: 1 })
      future = Process.clock_gettime(Process::CLOCK_REALTIME) + 10

      result = store.read(store: :items, key: "i1", as_of: future)
      expect(result).to include(x: 1, migrated: true)
    end

    it "applies coercion on scope query facts" do
      store = described_class.new
      store.register_path(
        Igniter::Store::AccessPath.new(
          store: :items, lookup: :primary_key, scope: :active,
          filters: { active: true }, cache_ttl: nil, consumers: []
        )
      )
      store.register_coercion(:items) { |v, _sv| v.merge(coerced: true) }

      store.write(store: :items, key: "i1", value: { active: true, name: "A" })
      results = store.query(store: :items, scope: :active)

      expect(results.map { |f| f.value }).to all(include(coerced: true))
    end

    it "applies coercion on history facts" do
      store = described_class.new
      store.register_coercion(:logs) { |v, _sv| v.merge(migrated: true) }

      store.append(history: :logs, event: { action: :created })
      results = store.history(store: :logs)

      expect(results.map { |f| f.value }).to all(include(migrated: true))
    end

    it "does not affect stores without a registered coercion" do
      store = described_class.new
      store.register_coercion(:other) { |v, _| v.merge(touched: true) }

      store.write(store: :items, key: "i1", value: { x: 1 })
      result = store.read(store: :items, key: "i1")

      expect(result).to eq({ x: 1 })
    end

    it "returns the original fact from query when value is not changed by coercion" do
      store = described_class.new
      store.register_path(
        Igniter::Store::AccessPath.new(
          store: :items, lookup: :primary_key, scope: :active,
          filters: { active: true }, cache_ttl: nil, consumers: []
        )
      )
      # Coercion returns the same object → no CoercedFact wrapping needed
      store.register_coercion(:items) { |v, _| v }

      store.write(store: :items, key: "i1", value: { active: true } )
      results = store.query(store: :items, scope: :active)

      expect(results.first).to be_a(Igniter::Store::Fact)
    end

    it "wraps fact in CoercedFact when coercion changes the value" do
      store = described_class.new
      store.register_path(
        Igniter::Store::AccessPath.new(
          store: :items, lookup: :primary_key, scope: :active,
          filters: { active: true }, cache_ttl: nil, consumers: []
        )
      )
      store.register_coercion(:items) { |v, _| v.merge(extra: 1) }

      store.write(store: :items, key: "i1", value: { active: true })
      results = store.query(store: :items, scope: :active)

      expect(results.first).to be_a(Igniter::Store::CoercedFact)
      expect(results.first.key).to eq("i1")
      expect(results.first.value).to include(extra: 1)
    end
  end

  describe "history_partition" do
    let(:store) { described_class.new }

    it "returns only events matching the partition value" do
      store.append(history: :logs, event: { tracker_id: "sleep", value: 8.0 }, partition_key: :tracker_id)
      store.append(history: :logs, event: { tracker_id: "mood",  value: 7.0 }, partition_key: :tracker_id)
      store.append(history: :logs, event: { tracker_id: "sleep", value: 7.5 }, partition_key: :tracker_id)

      results = store.history_partition(store: :logs, partition_key: :tracker_id, partition_value: "sleep")
      expect(results.map { |f| f.value[:value] }).to eq([8.0, 7.5])
    end

    it "returns an empty array for an unknown partition value" do
      store.append(history: :logs, event: { tracker_id: "sleep", value: 8.0 }, partition_key: :tracker_id)

      results = store.history_partition(store: :logs, partition_key: :tracker_id, partition_value: "mood")
      expect(results).to be_empty
    end

    it "builds the index lazily on first call and serves subsequent calls from it" do
      store.append(history: :logs, event: { tracker_id: "sleep", value: 8.0 }, partition_key: :tracker_id)
      store.append(history: :logs, event: { tracker_id: "sleep", value: 7.5 }, partition_key: :tracker_id)

      # First call — full scan
      first = store.history_partition(store: :logs, partition_key: :tracker_id, partition_value: "sleep")
      # Second call — served from index (object identity of facts is preserved)
      second = store.history_partition(store: :logs, partition_key: :tracker_id, partition_value: "sleep")
      expect(first.map(&:id)).to eq(second.map(&:id))
    end

    it "maintains the index for subsequent appends" do
      store.history_partition(store: :logs, partition_key: :tracker_id, partition_value: "sleep")  # warm empty

      store.append(history: :logs, event: { tracker_id: "sleep", value: 8.0 }, partition_key: :tracker_id)
      store.append(history: :logs, event: { tracker_id: "sleep", value: 7.5 }, partition_key: :tracker_id)

      results = store.history_partition(store: :logs, partition_key: :tracker_id, partition_value: "sleep")
      expect(results.length).to eq(2)
    end

    it "does not include new appends in the index when partition_key is not specified" do
      store.history_partition(store: :logs, partition_key: :tracker_id, partition_value: "sleep")  # warm

      # append without partition_key — index not updated
      store.append(history: :logs, event: { tracker_id: "sleep", value: 9.0 })

      results = store.history_partition(store: :logs, partition_key: :tracker_id, partition_value: "sleep")
      expect(results).to be_empty
    end

    it "filters by since:" do
      store.append(history: :logs, event: { tracker_id: "sleep", value: 8.0 }, partition_key: :tracker_id)
      sleep 0.01
      boundary = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.01
      store.append(history: :logs, event: { tracker_id: "sleep", value: 7.5 }, partition_key: :tracker_id)

      results = store.history_partition(
        store: :logs, partition_key: :tracker_id, partition_value: "sleep", since: boundary
      )
      expect(results.map { |f| f.value[:value] }).to eq([7.5])
    end

    it "filters by as_of:" do
      store.append(history: :logs, event: { tracker_id: "sleep", value: 8.0 }, partition_key: :tracker_id)
      sleep 0.01
      boundary = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.01
      store.append(history: :logs, event: { tracker_id: "sleep", value: 7.5 }, partition_key: :tracker_id)

      results = store.history_partition(
        store: :logs, partition_key: :tracker_id, partition_value: "sleep", as_of: boundary
      )
      expect(results.map { |f| f.value[:value] }).to eq([8.0])
    end
  end

  describe "scope-aware invalidation" do
    def path_for(scope, filters, consumers: [])
      Igniter::Store::AccessPath.new(
        store: :tasks, lookup: :primary_key, scope: scope,
        filters: filters, cache_ttl: nil, consumers: consumers
      )
    end

    it "does not notify scope consumers when write does not change scope membership" do
      store      = described_class.new
      fired      = []
      store.register_path(path_for(:pending, { status: :pending },
                                   consumers: [->(s, sc) { fired << sc }]))

      store.write(store: :tasks, key: "t1", value: { status: :pending })
      store.query(store: :tasks, scope: :pending)  # warm index
      fired.clear

      # Only title changes; status (the scope filter field) is unchanged
      store.write(store: :tasks, key: "t1", value: { status: :pending, title: "Updated" })
      expect(fired).to be_empty
    end

    it "notifies scope consumers when a key enters the scope" do
      store = described_class.new
      fired = []
      store.register_path(path_for(:pending, { status: :pending },
                                   consumers: [->(s, sc) { fired << sc }]))

      store.query(store: :tasks, scope: :pending)  # warm empty index
      fired.clear

      store.write(store: :tasks, key: "t1", value: { status: :pending })
      expect(fired).to eq([:pending])
    end

    it "notifies scope consumers when a key leaves the scope" do
      store = described_class.new
      fired = []
      store.register_path(path_for(:pending, { status: :pending },
                                   consumers: [->(s, sc) { fired << sc }]))

      store.write(store: :tasks, key: "t1", value: { status: :pending })
      store.query(store: :tasks, scope: :pending)  # warm index: {t1}
      fired.clear

      store.write(store: :tasks, key: "t1", value: { status: :done })
      expect(fired).to eq([:pending])
    end

    it "does not notify scope consumers before the scope cache is warmed" do
      store = described_class.new
      fired = []
      store.register_path(path_for(:pending, { status: :pending },
                                   consumers: [->(s, sc) { fired << sc }]))

      # No query yet — cache cold, consumers should not be spammed
      store.write(store: :tasks, key: "t1", value: { status: :pending })
      expect(fired).to be_empty
    end
  end
end
