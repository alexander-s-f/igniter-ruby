# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Store::ReadCache do
  describe "LRU cap on time-travel entries" do
    it "does not evict entries when below the cap" do
      cache = described_class.new(lru_cap: 10)
      t = 1_000.0

      5.times do |i|
        cache.put(store: :s, key: "k#{i}", fact: double("f#{i}"), as_of: t + i)
      end

      expect(cache.lru_size).to eq(5)
      5.times do |i|
        expect(cache.get(store: :s, key: "k#{i}", as_of: t + i)).not_to be_nil
      end
    end

    it "evicts the least recently used time-travel entry when cap is exceeded" do
      cache = described_class.new(lru_cap: 3)
      t = 1_000.0

      cache.put(store: :s, key: "k1", fact: double("f1"), as_of: t + 1)
      cache.put(store: :s, key: "k2", fact: double("f2"), as_of: t + 2)
      cache.put(store: :s, key: "k3", fact: double("f3"), as_of: t + 3)
      # Adding a 4th entry should evict k1 (oldest)
      cache.put(store: :s, key: "k4", fact: double("f4"), as_of: t + 4)

      expect(cache.lru_size).to eq(3)
      expect(cache.get(store: :s, key: "k1", as_of: t + 1)).to be_nil
      expect(cache.get(store: :s, key: "k2", as_of: t + 2)).not_to be_nil
      expect(cache.get(store: :s, key: "k3", as_of: t + 3)).not_to be_nil
      expect(cache.get(store: :s, key: "k4", as_of: t + 4)).not_to be_nil
    end

    it "promotes an accessed entry to MRU so it is not the next eviction target" do
      cache = described_class.new(lru_cap: 3)
      t = 1_000.0

      cache.put(store: :s, key: "k1", fact: double("f1"), as_of: t + 1)
      cache.put(store: :s, key: "k2", fact: double("f2"), as_of: t + 2)
      cache.put(store: :s, key: "k3", fact: double("f3"), as_of: t + 3)
      # Touch k1 — it should be promoted to MRU (k2 becomes LRU)
      cache.get(store: :s, key: "k1", as_of: t + 1)

      cache.put(store: :s, key: "k4", fact: double("f4"), as_of: t + 4)

      # k2 was LRU after k1 was promoted; k2 should be evicted, k1 should survive
      expect(cache.get(store: :s, key: "k1", as_of: t + 1)).not_to be_nil
      expect(cache.get(store: :s, key: "k2", as_of: t + 2)).to be_nil
      expect(cache.get(store: :s, key: "k3", as_of: t + 3)).not_to be_nil
      expect(cache.get(store: :s, key: "k4", as_of: t + 4)).not_to be_nil
    end

    it "does not count current-state entries (as_of: nil) against the LRU cap" do
      cache = described_class.new(lru_cap: 2)
      t = 1_000.0

      # Two time-travel entries fill the cap
      cache.put(store: :s, key: "k1", fact: double("f1"), as_of: t + 1)
      cache.put(store: :s, key: "k2", fact: double("f2"), as_of: t + 2)
      # Many current-state entries — should NOT count against cap or trigger eviction
      10.times { |i| cache.put(store: :s, key: "c#{i}", fact: double("cf#{i}"), as_of: nil) }

      expect(cache.lru_size).to eq(2)
      expect(cache.get(store: :s, key: "k1", as_of: t + 1)).not_to be_nil
      expect(cache.get(store: :s, key: "k2", as_of: t + 2)).not_to be_nil
      10.times do |i|
        expect(cache.get(store: :s, key: "c#{i}", as_of: nil)).not_to be_nil
      end
    end

    it "also caps scope time-travel entries (put_scope / get_scope with as_of)" do
      cache = described_class.new(lru_cap: 2)
      t = 1_000.0

      cache.put_scope(store: :s, scope: :open, facts: [], as_of: t + 1)
      cache.put_scope(store: :s, scope: :open, facts: [], as_of: t + 2)
      cache.put_scope(store: :s, scope: :open, facts: [], as_of: t + 3)

      expect(cache.lru_size).to eq(2)
      expect(cache.get_scope(store: :s, scope: :open, as_of: t + 1)).to be_nil
      expect(cache.get_scope(store: :s, scope: :open, as_of: t + 2)).not_to be_nil
      expect(cache.get_scope(store: :s, scope: :open, as_of: t + 3)).not_to be_nil
    end

    it "removes invalidated time-travel entries from the LRU tracker" do
      cache = described_class.new(lru_cap: 10)
      t = 1_000.0

      cache.put(store: :s, key: "k1", fact: double("f1"), as_of: t + 1)
      cache.put(store: :s, key: "k1", fact: double("f2"), as_of: nil)
      expect(cache.lru_size).to eq(1)

      cache.invalidate(store: :s, key: "k1")
      expect(cache.lru_size).to eq(0)
      expect(cache.get(store: :s, key: "k1", as_of: t + 1)).to be_nil
    end
  end

  describe "LRU cap via IgniterStore" do
    it "respects lru_cap: passed to IgniterStore constructor" do
      store = Igniter::Store::IgniterStore.new(lru_cap: 3)
      store.write(store: :r, key: "k1", value: { v: 1 })
      # Use timestamps in the future so latest_for returns the fact and put is called
      base = Process.clock_gettime(Process::CLOCK_REALTIME) + 10

      4.times { |i| store.read(store: :r, key: "k1", as_of: base + i) }

      # Only the 3 most recent time-travel reads should remain cached
      expect(store.instance_variable_get(:@cache).lru_size).to eq(3)
    end
  end
end
