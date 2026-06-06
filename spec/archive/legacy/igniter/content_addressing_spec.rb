# frozen_string_literal: true

require "spec_helper"
require "igniter/extensions/content_addressing"

RSpec.describe Igniter::ContentAddressing do
  before { Igniter::ContentAddressing.cache.clear }

  # ─── ContentKey ───────────────────────────────────────────────────────────

  describe Igniter::ContentAddressing::ContentKey do
    let(:executor_class) do
      Class.new(Igniter::Executor) do
        pure
        fingerprint "test_exec_v1"

        def call(x:, y:) = x + y
      end
    end

    it "produces the same key for identical inputs" do
      k1 = described_class.compute(executor_class, { x: 1, y: 2 })
      k2 = described_class.compute(executor_class, { x: 1, y: 2 })
      expect(k1).to eq(k2)
    end

    it "produces different keys for different values" do
      k1 = described_class.compute(executor_class, { x: 1, y: 2 })
      k2 = described_class.compute(executor_class, { x: 1, y: 3 })
      expect(k1).not_to eq(k2)
    end

    it "is order-independent for Hash deps" do
      k1 = described_class.compute(executor_class, { x: 1, y: 2 })
      k2 = described_class.compute(executor_class, { y: 2, x: 1 })
      expect(k1).to eq(k2)
    end

    it "changes when fingerprint changes" do
      v1 = Class.new(Igniter::Executor) { pure; fingerprint "v1"; def call(**); end }
      v2 = Class.new(Igniter::Executor) { pure; fingerprint "v2"; def call(**); end }
      k1 = described_class.compute(v1, { x: 1 })
      k2 = described_class.compute(v2, { x: 1 })
      expect(k1).not_to eq(k2)
    end

    it "has a ca: prefix in to_s" do
      k = described_class.compute(executor_class, { x: 1 })
      expect(k.to_s).to start_with("ca:")
    end

    it "is frozen" do
      k = described_class.compute(executor_class, { x: 1 })
      expect(k).to be_frozen
    end
  end

  # ─── Cache ────────────────────────────────────────────────────────────────

  describe Igniter::ContentAddressing::Cache do
    subject(:cache) { described_class.new }

    let(:key) do
      ec = Class.new(Igniter::Executor) { pure; def call(**); end }
      Igniter::ContentAddressing::ContentKey.compute(ec, { x: 1 })
    end

    it "returns nil on miss and increments miss counter" do
      expect(cache.fetch(key)).to be_nil
      expect(cache.stats[:misses]).to eq(1)
    end

    it "stores and retrieves a value" do
      cache.store(key, 42)
      expect(cache.fetch(key)).to eq(42)
      expect(cache.stats[:hits]).to eq(1)
    end

    it "tracks size" do
      cache.store(key, "value")
      expect(cache.size).to eq(1)
    end

    it "clears all entries and resets counters" do
      cache.store(key, "value")
      cache.fetch(key)
      cache.clear
      expect(cache.size).to eq(0)
      expect(cache.stats[:hits]).to eq(0)
    end
  end

  # ─── Runtime integration ──────────────────────────────────────────────────

  describe "runtime content cache hit" do
    let(:call_count) { [] }

    let(:pure_executor) do
      tracker = call_count
      Class.new(Igniter::Executor) do
        pure
        fingerprint "tracked_pure_v1"

        define_method(:call) do |x:|
          tracker << :called
          x * 10
        end
      end
    end

    let(:contract_class) do
      pe = pure_executor
      Class.new(Igniter::Contract) do
        define do
          input :x
          compute :result, depends_on: :x, call: pe
          output :result
        end
      end
    end

    it "computes on first call and caches the result" do
      c = contract_class.new(x: 5)
      c.resolve_all
      expect(c.result.result).to eq(50)
      expect(call_count.length).to eq(1)
    end

    it "uses content cache on second independent execution with same inputs" do
      contract_class.new(x: 5).resolve_all
      c2 = contract_class.new(x: 5)
      c2.resolve_all
      expect(c2.result.result).to eq(50)
      expect(call_count.length).to eq(1) # executor called only once across both executions
    end

    it "recomputes when inputs change" do
      contract_class.new(x: 5).resolve_all
      contract_class.new(x: 7).resolve_all
      expect(call_count.length).to eq(2)
    end

    it "emits :node_content_cache_hit event on cache hit" do
      contract_class.new(x: 5).resolve_all

      events = []
      c2 = contract_class.new(x: 5)
      c2.execution.events.subscribe do |event|
        events << event.type if event.type == :node_content_cache_hit
      end
      c2.resolve_all

      expect(events).to include(:node_content_cache_hit)
    end

    it "non-pure executors are not cached across executions" do
      non_pure_tracker = []
      non_pure = Class.new(Igniter::Executor) do
        # no `pure` declaration
        define_method(:call) { |x:| non_pure_tracker << :called; x * 2 }
      end

      klass = Class.new(Igniter::Contract) do
        define { input :x; compute :r, depends_on: :x, call: non_pure; output :r }
      end

      klass.new(x: 3).resolve_all
      klass.new(x: 3).resolve_all
      expect(non_pure_tracker.length).to eq(2)
    end
  end

  # ─── Executor DSL ────────────────────────────────────────────────────────

  describe "Executor DSL integration" do
    it "fingerprint returns class name by default" do
      klass = Class.new(Igniter::Executor) { pure }
      # Class.name is nil for anonymous classes; should fall back to anonymous_executor
      expect(klass.content_fingerprint).to eq("anonymous_executor")
    end

    it "fingerprint can be set explicitly" do
      klass = Class.new(Igniter::Executor) { pure; fingerprint "my_exec_v2" }
      expect(klass.content_fingerprint).to eq("my_exec_v2")
    end
  end
end
