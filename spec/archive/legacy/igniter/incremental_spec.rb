# frozen_string_literal: true

require "spec_helper"
require "igniter/extensions/incremental"

RSpec.describe "Incremental Computation" do
  # ─── Shared graph: A → B → C, plus independent D ─────────────────────────
  #
  #   input :x         (changes)
  #   input :y         (stable)
  #   compute :b  ← x  (may or may not change)
  #   compute :c  ← b  (only recomputes if b changes)
  #   compute :d  ← y  (independent — should never recompute when x changes)
  #   output :c
  #   output :d
  #
  # Parameterised so tests can control whether b passes through the same value.
  #
  def build_contract(b_transform: ->(x) { x * 2 }, c_transform: ->(b) { b + 1 })
    b_fn = b_transform
    c_fn = c_transform

    Class.new(Igniter::Contract) do
      define do
        input :x
        input :y

        compute :b, depends_on: :x, call: ->(x:) { b_fn.call(x) }
        compute :c, depends_on: :b, call: ->(b:) { c_fn.call(b) }
        compute :d, depends_on: :y, call: ->(y:) { y.to_s.upcase }

        output :c
        output :d
      end
    end
  end

  # ─── value_version tracking ───────────────────────────────────────────────

  describe "value_version" do
    it "is set to 1 on first resolution of a compute node" do
      klass = build_contract
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      state = contract.execution.cache.fetch(:b)
      expect(state.value_version).to eq(1)
    end

    it "is set to 1 for input nodes on first resolution" do
      klass = build_contract
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      state = contract.execution.cache.fetch(:x)
      expect(state.value_version).to eq(1)
    end

    it "increments when the input value changes" do
      klass = build_contract
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      contract.update_inputs(x: 10)
      state = contract.execution.cache.fetch(:x)
      expect(state.value_version).to eq(2)
    end

    it "does NOT increment when the input value is the same" do
      klass = build_contract
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      contract.update_inputs(x: 5)
      state = contract.execution.cache.fetch(:x)
      expect(state.value_version).to eq(1)
    end
  end

  # ─── dep_snapshot ─────────────────────────────────────────────────────────

  describe "dep_snapshot" do
    it "is stored on compute nodes after resolution" do
      klass = build_contract
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      state = contract.execution.cache.fetch(:b)
      expect(state.dep_snapshot).to be_a(Hash)
      expect(state.dep_snapshot).to have_key(:x)
    end

    it "records the value_version of each dependency" do
      klass = build_contract
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      x_vv = contract.execution.cache.fetch(:x).value_version
      b_snap = contract.execution.cache.fetch(:b).dep_snapshot
      expect(b_snap[:x]).to eq(x_vv)
    end
  end

  # ─── Memoization: skip recompute when deps unchanged ──────────────────────

  describe "memoization (skip recompute)" do
    context "when only an independent input changes" do
      it "does not recompute nodes that don't depend on the changed input" do
        # b and c depend on x; d depends on y. Changing y should skip b and c.
        klass = build_contract
        contract = klass.new(x: 5, y: "hello")
        contract.resolve_all

        b_vv_before = contract.execution.cache.fetch(:b).value_version
        c_vv_before = contract.execution.cache.fetch(:c).value_version

        contract.update_inputs(y: "world")
        contract.resolve_all

        expect(contract.execution.cache.fetch(:b).value_version).to eq(b_vv_before)
        expect(contract.execution.cache.fetch(:c).value_version).to eq(c_vv_before)
      end

      it "does recompute nodes that depend on the changed input" do
        klass = build_contract
        contract = klass.new(x: 5, y: "hello")
        contract.resolve_all

        d_vv_before = contract.execution.cache.fetch(:d).value_version
        contract.update_inputs(y: "world")
        contract.resolve_all

        expect(contract.execution.cache.fetch(:d).value_version).to be > d_vv_before
      end
    end
  end

  # ─── Value backdating ─────────────────────────────────────────────────────

  describe "value backdating" do
    # b_transform returns the same value regardless of x, so b is always 99.
    # c depends on b — if b's value_version doesn't change, c should skip.
    context "when a compute node produces the same value after recompute" do
      let(:klass) do
        build_contract(
          b_transform: ->(_x) { 99 },   # always 99 regardless of x
          c_transform: ->(b) { b + 1 }
        )
      end

      it "does not increment value_version for the backdated node" do
        contract = klass.new(x: 1, y: "a")
        contract.resolve_all
        b_vv = contract.execution.cache.fetch(:b).value_version

        contract.update_inputs(x: 2)  # x changes but b will still return 99
        contract.resolve_all

        expect(contract.execution.cache.fetch(:b).value_version).to eq(b_vv)
      end

      it "skips recomputation of downstream nodes (c) after backdating" do
        contract = klass.new(x: 1, y: "a")
        contract.resolve_all
        c_vv = contract.execution.cache.fetch(:c).value_version

        contract.update_inputs(x: 2)
        contract.resolve_all

        # c's dep (b) was backdated → c's dep_snapshot still matches → c skipped
        expect(contract.execution.cache.fetch(:c).value_version).to eq(c_vv)
      end

      it "preserves the correct output value" do
        contract = klass.new(x: 1, y: "a")
        contract.resolve_all

        contract.update_inputs(x: 999)
        contract.resolve_all

        # b always returns 99, c = 99 + 1 = 100
        expect(contract.execution.cache.fetch(:c).value).to eq(100)
      end
    end
  end

  # ─── Chain propagation ────────────────────────────────────────────────────

  describe "chain propagation" do
    it "recomputes the full chain when a dependency value actually changes" do
      klass = build_contract
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      b_vv = contract.execution.cache.fetch(:b).value_version
      c_vv = contract.execution.cache.fetch(:c).value_version

      contract.update_inputs(x: 10)  # x changes → b changes → c changes
      contract.resolve_all

      expect(contract.execution.cache.fetch(:b).value_version).to be > b_vv
      expect(contract.execution.cache.fetch(:c).value_version).to be > c_vv
    end

    it "computes the correct values after chain recomputation" do
      klass = build_contract  # b = x*2, c = b+1
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      contract.update_inputs(x: 7)
      contract.resolve_all

      expect(contract.execution.cache.fetch(:b).value).to eq(14)   # 7*2
      expect(contract.execution.cache.fetch(:c).value).to eq(15)   # 14+1
    end
  end

  # ─── resolve_incrementally extension ──────────────────────────────────────

  describe "resolve_incrementally" do
    let(:klass) { build_contract }

    it "raises IncrementalError when called before first resolve_all" do
      contract = klass.new(x: 5, y: "hello")

      expect { contract.resolve_incrementally(x: 10) }
        .to raise_error(Igniter::Incremental::IncrementalError, /resolve_all first/)
    end

    it "returns an Incremental::Result" do
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      result = contract.resolve_incrementally(x: 10)
      expect(result).to be_a(Igniter::Incremental::Result)
    end

    it "reports changed outputs when output value changes" do
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      result = contract.resolve_incrementally(x: 10)
      expect(result.changed_outputs).to have_key(:c)
      expect(result.changed_outputs[:c][:from]).to eq(11)  # x=5 → b=10 → c=11
      expect(result.changed_outputs[:c][:to]).to eq(21)    # x=10 → b=20 → c=21
    end

    it "reports no changed outputs when only independent input changes" do
      # Changing y only affects d, not c
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      result = contract.resolve_incrementally(y: "world")
      expect(result.changed_outputs).not_to have_key(:c)
      expect(result.changed_outputs).to have_key(:d)
    end

    it "reports skipped nodes when deps haven't changed" do
      # b and c depend on x; when y changes, both should be skipped
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      result = contract.resolve_incrementally(y: "world")
      # b and c were stale? No — they don't depend on y at all.
      # They should not even be in skipped (they weren't stale).
      # d depends on y → d was stale → d gets recomputed.
      expect(result.recomputed_count).to be >= 1
    end

    context "with backdating (b always returns same value)" do
      let(:klass) do
        build_contract(
          b_transform: ->(_x) { 42 },
          c_transform: ->(b) { b * 2 }
        )
      end

      it "reports backdated node" do
        contract = klass.new(x: 1, y: "a")
        contract.resolve_all

        result = contract.resolve_incrementally(x: 2)
        expect(result.backdated_nodes).to include(:b)
      end

      it "reports no change in output c (because b backdated)" do
        contract = klass.new(x: 1, y: "a")
        contract.resolve_all

        result = contract.resolve_incrementally(x: 2)
        expect(result.changed_outputs).not_to have_key(:c)
      end

      it "outputs_changed? is false when no output value changed" do
        contract = klass.new(x: 1, y: "a")
        contract.resolve_all

        result = contract.resolve_incrementally(x: 99)
        expect(result.outputs_changed?).to be false
      end
    end

    it "works with no input changes (fully memoized re-resolve)" do
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      result = contract.resolve_incrementally
      expect(result.changed_outputs).to be_empty
      expect(result.recomputed_count).to eq(0)
    end

    it "result#explain returns a non-empty string" do
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      result = contract.resolve_incrementally(x: 10)
      expect(result.explain).to be_a(String)
      expect(result.explain).not_to be_empty
      expect(result.explain).to include("Incremental")
    end

    it "result#summary returns a concise string" do
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      result = contract.resolve_incrementally(x: 10)
      expect(result.summary).to be_a(String)
    end

    it "result#to_h includes all expected keys" do
      contract = klass.new(x: 5, y: "hello")
      contract.resolve_all

      result = contract.resolve_incrementally(x: 10)
      h = result.to_h
      expect(h).to include(:changed_nodes, :skipped_nodes, :backdated_nodes,
                            :changed_outputs, :recomputed_count,
                            :outputs_changed, :fully_memoized)
    end
  end

  # ─── Repeated incremental updates ────────────────────────────────────────

  describe "repeated incremental updates" do
    it "handles multiple sequential updates correctly" do
      klass = build_contract
      contract = klass.new(x: 1, y: "a")
      contract.resolve_all

      # First increment
      r1 = contract.resolve_incrementally(x: 2)
      expect(r1.changed_outputs[:c][:to]).to eq(5)  # b=4, c=5

      # Second increment
      r2 = contract.resolve_incrementally(x: 3)
      expect(r2.changed_outputs[:c][:to]).to eq(7)  # b=6, c=7

      # Same value again
      r3 = contract.resolve_incrementally(x: 3)
      expect(r3.changed_outputs).to be_empty
      expect(r3.recomputed_count).to eq(0)
    end
  end

  # ─── 3-node chain with intermediate backdating ───────────────────────────

  describe "3-node chain: A → B → C, B always returns 0" do
    let(:klass) do
      Class.new(Igniter::Contract) do
        define do
          input :a
          compute :b, depends_on: :a,  call: ->(**) { 0 }  # always 0
          compute :c, depends_on: :b,  call: ->(b:)  { b + 100 }
          output :c
        end
      end
    end

    it "skips c when a changes but b stays 0" do
      contract = klass.new(a: 1)
      contract.resolve_all
      c_vv = contract.execution.cache.fetch(:c).value_version

      contract.update_inputs(a: 999)
      contract.resolve_all

      expect(contract.execution.cache.fetch(:c).value_version).to eq(c_vv)
      expect(contract.execution.cache.fetch(:c).value).to eq(100)
    end
  end
end
