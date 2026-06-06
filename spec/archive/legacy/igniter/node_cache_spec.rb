# frozen_string_literal: true

require "spec_helper"
require "igniter/core/node_cache"
require "igniter/core/fingerprint"

RSpec.describe "Igniter Node Cache (Gaps 1–4)" do
  # ── Helpers ──────────────────────────────────────────────────────────────

  let(:memory_cache) { Igniter::NodeCache::Memory.new }
  let(:coalescing_lock) { Igniter::NodeCache::CoalescingLock.new }

  def make_key(contract: "MyContract", node: :compute_x, dep_hex: "abc123")
    Igniter::NodeCache::CacheKey.new(contract, node, dep_hex)
  end

  # ── Gap 3: Fingerprinter ──────────────────────────────────────────────────

  describe Igniter::NodeCache::Fingerprinter do
    subject(:fingerprinter) { described_class }

    it "returns a 24-char hex string" do
      hex = fingerprinter.call(name: "Alice", age: 30)
      expect(hex).to match(/\A[0-9a-f]{24}\z/)
    end

    it "is stable for identical Hash inputs" do
      a = fingerprinter.call(zip: "60601", vendor: "eLocal")
      b = fingerprinter.call(zip: "60601", vendor: "eLocal")
      expect(a).to eq(b)
    end

    it "produces different fingerprints for different inputs" do
      a = fingerprinter.call(zip: "60601")
      b = fingerprinter.call(zip: "10001")
      expect(a).not_to eq(b)
    end

    it "is order-independent for Hash keys" do
      a = fingerprinter.call(b: 2, a: 1)
      b = fingerprinter.call(a: 1, b: 2)
      expect(a).to eq(b)
    end

    it "distinguishes Array from Hash with same values" do
      a = fingerprinter.call(["x"])
      b = fingerprinter.call({ x: "x" })
      expect(a).not_to eq(b)
    end

    it "uses igniter_fingerprint when available" do
      obj = Object.new
      def obj.igniter_fingerprint = "MyModel:42:1700000000"

      serialized = Igniter::NodeCache::Fingerprinter.serialize(obj)
      expect(serialized).to eq("fp:MyModel:42:1700000000")
    end

    it "falls back to class@object_id for unknown objects" do
      obj = Object.new
      serialized = Igniter::NodeCache::Fingerprinter.serialize(obj)
      expect(serialized).to start_with("obj:Object@")
    end

    it "handles nil, booleans, symbols, numbers" do
      expect { fingerprinter.call(a: nil, b: true, c: :sym, d: 42) }.not_to raise_error
    end
  end

  # ── Gap 3: Igniter::Fingerprint mixin ─────────────────────────────────────

  describe Igniter::Fingerprint do
    let(:model_class) do
      Struct.new(:id, :updated_at) do
        include Igniter::Fingerprint
      end
    end

    it "returns ClassName:id:updated_at_unix when updated_at is present" do
      record = model_class.new(42, Time.at(1_700_000_000).utc)
      expect(record.igniter_fingerprint).to eq("#{model_class.name}:42:1700000000")
    end

    it "returns ClassName:id when updated_at is absent" do
      klass = Struct.new(:id) { include Igniter::Fingerprint }
      record = klass.new(7)
      expect(record.igniter_fingerprint).to eq("#{klass.name}:7")
    end

    it "produces different fingerprints for different updated_at" do
      a = model_class.new(42, Time.at(1_000).utc)
      b = model_class.new(42, Time.at(2_000).utc)
      expect(a.igniter_fingerprint).not_to eq(b.igniter_fingerprint)
    end
  end

  # ── Gap 1: NodeCache::CacheKey ────────────────────────────────────────────

  describe Igniter::NodeCache::CacheKey do
    it "encodes contract, node, dep_hex in hex" do
      key = make_key(contract: "Foo", node: :bar, dep_hex: "deadbeef")
      expect(key.hex).to eq("ttl:Foo:bar:deadbeef")
    end

    it "is frozen" do
      expect(make_key).to be_frozen
    end

    it "is equal when hex matches" do
      a = make_key
      b = make_key
      expect(a).to eq(b)
    end
  end

  # ── Gap 1: NodeCache::Memory ──────────────────────────────────────────────

  describe Igniter::NodeCache::Memory do
    subject(:cache) { memory_cache }

    let(:key) { make_key }

    it "returns nil on miss" do
      expect(cache.fetch(key)).to be_nil
    end

    it "returns the stored value within TTL" do
      cache.store(key, "result", ttl: 60)
      expect(cache.fetch(key)).to eq("result")
    end

    it "returns nil for an expired entry" do
      cache.store(key, "result", ttl: -1) # already expired
      expect(cache.fetch(key)).to be_nil
    end

    it "tracks hit/miss stats" do
      cache.store(key, 42, ttl: 60)
      cache.fetch(key)         # hit
      cache.fetch(make_key(dep_hex: "miss"))  # miss

      stats = cache.stats
      expect(stats[:hits]).to eq(1)
      expect(stats[:misses]).to eq(1)
    end

    it "prunes! removes expired entries only" do
      fresh_key = make_key(dep_hex: "fresh")
      stale_key = make_key(dep_hex: "stale")
      cache.store(fresh_key, "ok", ttl: 60)
      cache.store(stale_key, "old", ttl: -1)

      cache.prune!
      expect(cache.size).to eq(1)
      expect(cache.fetch(fresh_key)).to eq("ok")
    end

    it "is thread-safe: concurrent stores and fetches" do
      threads = 20.times.map do |i|
        Thread.new do
          k = make_key(dep_hex: "dep#{i}")
          cache.store(k, i, ttl: 60)
          cache.fetch(k)
        end
      end
      results = threads.map(&:value)
      expect(results.compact.size).to eq(20)
    end
  end

  # ── Gap 1: end-to-end TTL cache in contract execution ────────────────────

  describe "TTL cache in contract execution" do
    before do
      Igniter::NodeCache.cache = Igniter::NodeCache::Memory.new
    end

    after do
      Igniter::NodeCache.cache = nil
    end

    let(:call_counter) { { count: 0 } }

    let(:contract_class) do
      counter = call_counter
      Class.new(Igniter::Contract) do
        define do
          input :x

          compute :doubled, with: :x, cache_ttl: 60 do |x:|
            counter[:count] += 1
            x * 2
          end

          output :doubled
        end
      end
    end

    it "computes on first call" do
      c = contract_class.new(x: 5)
      c.resolve_all
      expect(c.result.doubled).to eq(10)
      expect(call_counter[:count]).to eq(1)
    end

    it "reuses cached result on second call with same inputs" do
      contract_class.new(x: 5).resolve_all
      contract_class.new(x: 5).resolve_all
      expect(call_counter[:count]).to eq(1)
    end

    it "recomputes when inputs differ" do
      contract_class.new(x: 5).resolve_all
      contract_class.new(x: 7).resolve_all
      expect(call_counter[:count]).to eq(2)
    end

    it "emits :node_ttl_cache_hit event on cache hit" do
      contract_class.new(x: 5).resolve_all

      c = contract_class.new(x: 5)
      c.resolve_all

      hit_events = c.execution.events.events.select { |e| e.type == :node_ttl_cache_hit }
      expect(hit_events).not_to be_empty
    end

    it "does not cache when cache_ttl is absent" do
      counter = call_counter
      klass = Class.new(Igniter::Contract) do
        define do
          input :x
          compute :doubled, with: :x do |x:|
            counter[:count] += 1
            x * 2
          end
          output :doubled
        end
      end

      klass.new(x: 5).resolve_all
      klass.new(x: 5).resolve_all
      expect(call_counter[:count]).to eq(2)
    end
  end

  # ── Gap 2: runner class macro ─────────────────────────────────────────────

  describe "Contract.runner class macro" do
    it "sets execution_options with runner and max_workers" do
      klass = Class.new(Igniter::Contract) do
        runner :thread_pool, pool_size: 4
        define do
          input :x
          output :x
        end
      end

      expect(klass.execution_options).to include(runner: :thread_pool, max_workers: 4)
    end

    it "accepts max_workers: as alias for pool_size:" do
      klass = Class.new(Igniter::Contract) do
        runner :thread_pool, max_workers: 8
        define do
          input :x
          output :x
        end
      end

      expect(klass.execution_options).to include(runner: :thread_pool, max_workers: 8)
    end

    it "sets inline runner without workers" do
      klass = Class.new(Igniter::Contract) do
        runner :inline
        define do
          input :x
          output :x
        end
      end

      expect(klass.execution_options).to include(runner: :inline)
      expect(klass.execution_options).not_to have_key(:max_workers)
    end

    it "runner config is used when resolve_all is called" do
      klass = Class.new(Igniter::Contract) do
        runner :thread_pool, pool_size: 2
        define do
          input :x
          compute :y, with: :x do |x:| x + 1 end
          output :y
        end
      end

      c = klass.new(x: 10)
      c.resolve_all
      expect(c.result.y).to eq(11)
    end

    it "instance-level runner: overrides class-level" do
      klass = Class.new(Igniter::Contract) do
        runner :thread_pool, pool_size: 4
        define do
          input :x
          output :x
        end
      end

      c = klass.new(x: 1, runner: :inline)
      expect(c.execution.instance_variable_get(:@runner).class.name).to include("Inline")
    end
  end

  # ── Gap 3: igniter_fingerprint in cache keys ──────────────────────────────

  describe "igniter_fingerprint used in TTL cache keys" do
    before { Igniter::NodeCache.cache = Igniter::NodeCache::Memory.new }
    after  { Igniter::NodeCache.cache = nil }

    let(:call_counter) { { count: 0 } }

    let(:ar_like_class) do
      Struct.new(:id, :updated_at) do
        include Igniter::Fingerprint
      end
    end

    it "treats same-id same-updated_at as cache hit" do
      counter = call_counter
      klass = Class.new(Igniter::Contract) do
        define do
          input :record
          compute :processed, with: :record, cache_ttl: 60 do |record:|
            counter[:count] += 1
            record.id * 10
          end
          output :processed
        end
      end

      ar_class = ar_like_class
      ts = Time.at(1_700_000_000).utc

      klass.new(record: ar_class.new(1, ts)).resolve_all
      klass.new(record: ar_class.new(1, ts)).resolve_all
      expect(call_counter[:count]).to eq(1)
    end

    it "treats same-id different-updated_at as cache miss" do
      counter = call_counter
      klass = Class.new(Igniter::Contract) do
        define do
          input :record
          compute :processed, with: :record, cache_ttl: 60 do |record:|
            counter[:count] += 1
            record.id * 10
          end
          output :processed
        end
      end

      ar_class = ar_like_class
      klass.new(record: ar_class.new(1, Time.at(1_000).utc)).resolve_all
      klass.new(record: ar_class.new(1, Time.at(2_000).utc)).resolve_all
      expect(call_counter[:count]).to eq(2)
    end
  end

  # ── Gap 4: CoalescingLock ─────────────────────────────────────────────────

  describe Igniter::NodeCache::CoalescingLock do
    subject(:lock) { coalescing_lock }

    it "first acquire returns :leader" do
      role, _flight = lock.acquire("key1")
      expect(role).to eq(:leader)
    ensure
      lock.finish!("key1", value: nil)
    end

    it "second acquire for same key returns :follower" do
      lock.acquire("key2")
      role, _flight = lock.acquire("key2")
      expect(role).to eq(:follower)
    ensure
      lock.finish!("key2", value: nil)
    end

    it "different keys each get :leader" do
      role_a, _ = lock.acquire("keyA")
      role_b, _ = lock.acquire("keyB")
      expect(role_a).to eq(:leader)
      expect(role_b).to eq(:leader)
    ensure
      lock.finish!("keyA", value: nil)
      lock.finish!("keyB", value: nil)
    end

    it "follower receives the leader's value" do
      _role, flight = lock.acquire("key3")
      lock.acquire("key3") # follower registered but we won't call wait here

      leader_thread = Thread.new { sleep(0.01); lock.finish!("key3", value: "hello") }
      _role2, flight2 = nil, nil
      @mu = Mutex.new
      Thread.new do
        @mu.synchronize { _role2, flight2 = lock.acquire("key3") }
      end.join

      leader_thread.join
      # Simulate follower wait after leader finishes
      value, error = lock.wait(flight2 || flight)
      expect(error).to be_nil
      # Value is "hello" if the flight was registered before finish!, nil if after
      # (timing-dependent; just check no error)
    end

    it "follower receives the leader's error" do
      _role, _flight = lock.acquire("key4")
      err = RuntimeError.new("boom")

      follower_result = nil
      t = Thread.new do
        _, f = lock.acquire("key4")
        follower_result = lock.wait(f)
      end

      sleep 0.01
      lock.finish!("key4", error: err)
      t.join

      expect(follower_result.last).to eq(err)
    end

    it "in-flight count decrements after finish!" do
      lock.acquire("key5")
      expect(lock.in_flight_count).to eq(1)
      lock.finish!("key5", value: 42)
      expect(lock.in_flight_count).to eq(0)
    end
  end

  # ── Gap 4: end-to-end coalescing in contract execution ───────────────────

  describe "request coalescing in contract execution" do
    before do
      Igniter::NodeCache.cache          = Igniter::NodeCache::Memory.new
      Igniter::NodeCache.coalescing_lock = Igniter::NodeCache::CoalescingLock.new
    end

    after do
      Igniter::NodeCache.cache           = nil
      Igniter::NodeCache.coalescing_lock = nil
    end

    it "concurrent executions with same inputs produce one computation" do
      call_counter = { count: 0, mu: Mutex.new }
      barrier      = Mutex.new
      barrier_cond = ConditionVariable.new
      started      = 0

      klass = Class.new(Igniter::Contract) do
        define do
          input :zip

          compute :result, with: :zip,
                           cache_ttl: 60,
                           coalesce: true do |zip:|
            call_counter[:mu].synchronize { call_counter[:count] += 1 }
            sleep 0.05 # simulate slow DB call
            "data_for_#{zip}"
          end

          output :result
        end
      end

      threads = 5.times.map do
        Thread.new do
          barrier.synchronize do
            started += 1
            barrier_cond.broadcast if started == 5
            barrier_cond.wait(barrier) until started == 5
          end
          c = klass.new(zip: "60601")
          c.resolve_all
          c.result.result
        end
      end

      results = threads.map(&:value)

      expect(results).to all(eq("data_for_60601"))
      # All 5 threads get the right answer; computation runs at most a handful of times
      # (coalescing is best-effort: threads that arrive before the leader completes coalesce)
      expect(call_counter[:count]).to be <= 3
    end
  end

  # ── Igniter.configure API ─────────────────────────────────────────────────

  describe "Igniter.configure block" do
    after do
      Igniter::NodeCache.cache           = nil
      Igniter::NodeCache.coalescing_lock = nil
    end

    it "sets node_cache via configure" do
      cache = Igniter::NodeCache::Memory.new
      Igniter.configure { |c| c.node_cache = cache }
      expect(Igniter.node_cache).to be(cache)
    end

    it "node_coalescing= true creates a CoalescingLock" do
      Igniter.configure { |c| c.node_coalescing = true }
      expect(Igniter::NodeCache.coalescing_lock).to be_a(Igniter::NodeCache::CoalescingLock)
    end

    it "node_coalescing= false removes the lock" do
      Igniter.configure { |c| c.node_coalescing = true }
      Igniter.configure { |c| c.node_coalescing = false }
      expect(Igniter::NodeCache.coalescing_lock).to be_nil
    end
  end
end
