# frozen_string_literal: true

require "igniter"
require "igniter/extensions/invariants"
require "igniter/core/property_testing"

G = Igniter::PropertyTesting::Generators

RSpec.describe "Igniter Invariants and Property Testing" do
  # ── Shared helpers ───────────────────────────────────────────────────────────

  # A simple contract with one input, one compute, one output
  let(:pricing_class) do
    Class.new(Igniter::Contract) do
      define do
        input  :price
        input  :quantity
        compute :total, depends_on: %i[price quantity] do |price:, quantity:|
          price * quantity
        end
        output :total
      end
    end
  end

  # A contract with multiple outputs
  let(:multi_output_class) do
    Class.new(Igniter::Contract) do
      define do
        input  :price
        input  :quantity
        compute :subtotal, depends_on: %i[price quantity] do |price:, quantity:|
          price * quantity
        end
        compute :discount, depends_on: :subtotal do |subtotal:|
          subtotal > 100 ? subtotal * 0.1 : 0.0
        end
        compute :total, depends_on: %i[subtotal discount] do |subtotal:, discount:|
          subtotal - discount
        end
        output :total
        output :subtotal
        output :discount
      end
    end
  end

  # ── Igniter::Invariant ───────────────────────────────────────────────────────

  describe Igniter::Invariant do
    it "stores the name as a symbol" do
      inv = described_class.new(:total_positive) { true }
      expect(inv.name).to eq(:total_positive)
    end

    it "stores the block" do
      blk = -> { true }
      inv = described_class.new(:foo, &blk)
      expect(inv.block).to eq(blk)
    end

    it "freezes the object" do
      inv = described_class.new(:foo) { true }
      expect(inv).to be_frozen
    end

    it "raises ArgumentError when no block is given" do
      expect { Igniter::Invariant.new(:foo) }
        .to raise_error(ArgumentError, /requires a block/)
    end

    describe "#check" do
      it "returns nil when the condition holds" do
        inv = described_class.new(:pos) { |total:, **| total >= 0 }
        expect(inv.check(total: 10)).to be_nil
      end

      it "returns InvariantViolation when the condition is false" do
        inv = described_class.new(:pos) { |total:, **| total >= 0 }
        result = inv.check(total: -1)
        expect(result).to be_a(Igniter::InvariantViolation)
        expect(result.name).to eq(:pos)
        expect(result).to be_failed
      end

      it "captures an error thrown from the block as a violation" do
        inv = described_class.new(:buggy) { |**| raise "oops" }
        result = inv.check(total: 1)
        expect(result).to be_a(Igniter::InvariantViolation)
        expect(result).to be_failed
        expect(result.error).to be_a(RuntimeError)
        expect(result.error.message).to eq("oops")
      end

      it "passes all resolved values as keyword args" do
        received = {}
        inv = described_class.new(:spy) do |total:, subtotal:|
          received[:total]    = total
          received[:subtotal] = subtotal
          true
        end
        inv.check(total: 90, subtotal: 100)
        expect(received).to eq(total: 90, subtotal: 100)
      end
    end
  end

  # ── Igniter::InvariantViolation ──────────────────────────────────────────────

  describe Igniter::InvariantViolation do
    it "stores name as a symbol" do
      v = described_class.new(name: :foo, passed: false)
      expect(v.name).to eq(:foo)
    end

    it "reports passed? correctly" do
      expect(described_class.new(name: :foo, passed: true)).to be_passed
      expect(described_class.new(name: :foo, passed: false)).not_to be_passed
    end

    it "reports failed? correctly" do
      expect(described_class.new(name: :foo, passed: false)).to be_failed
      expect(described_class.new(name: :foo, passed: true)).not_to be_failed
    end

    it "stores an error when provided" do
      err = RuntimeError.new("boom")
      v   = described_class.new(name: :foo, passed: false, error: err)
      expect(v.error).to eq(err)
    end

    it "error is nil by default" do
      v = described_class.new(name: :foo, passed: false)
      expect(v.error).to be_nil
    end

    it "freezes the object" do
      v = described_class.new(name: :foo, passed: false)
      expect(v).to be_frozen
    end
  end

  # ── Igniter::InvariantError ───────────────────────────────────────────────────

  describe Igniter::InvariantError do
    it "carries a violations array" do
      viol  = Igniter::InvariantViolation.new(name: :pos, passed: false)
      error = described_class.new("1 violated", violations: [viol])
      expect(error.violations).to eq([viol])
    end

    it "violations array is frozen" do
      error = described_class.new("x", violations: [])
      expect(error.violations).to be_frozen
    end

    it "includes violation names in message" do
      v1 = Igniter::InvariantViolation.new(name: :pos, passed: false)
      v2 = Igniter::InvariantViolation.new(name: :non_zero, passed: false)
      error = described_class.new("2 invariant(s) violated: :pos, :non_zero", violations: [v1, v2])
      expect(error.message).to include(":pos")
      expect(error.message).to include(":non_zero")
    end

    it "inherits from Igniter::Error" do
      expect(described_class.new).to be_a(Igniter::Error)
    end
  end

  # ── Extensions::Invariants — class DSL ───────────────────────────────────────

  describe "invariant class DSL" do
    it "stores declarations on the class" do
      klass = pricing_class
      klass.invariant(:pos) { |total:, **| total >= 0 }
      expect(klass.invariants.keys).to include(:pos)
      expect(klass.invariants[:pos]).to be_a(Igniter::Invariant)
    end

    it "returns an empty hash when no invariants are declared" do
      klass = Class.new(Igniter::Contract) do
        define { input :x; output :x }
      end
      expect(klass.invariants).to eq({})
    end

    it "allows multiple invariants" do
      klass = pricing_class
      klass.invariant(:pos)      { |total:, **| total >= 0 }
      klass.invariant(:non_zero) { |total:, **| total != 0 }
      expect(klass.invariants.size).to eq(2)
    end

    it "does not leak invariants across independent contract classes" do
      a = Class.new(Igniter::Contract) do
        define { input :x; output :x }
        invariant(:a_check) { true }
      end
      b = Class.new(Igniter::Contract) do
        define { input :x; output :x }
      end
      expect(b.invariants).not_to have_key(:a_check)
    end
  end

  # ── resolve_all integration ───────────────────────────────────────────────────

  describe "resolve_all + automatic invariant check" do
    it "does nothing when no invariants are declared" do
      klass    = pricing_class
      contract = klass.new(price: 10.0, quantity: 5)
      expect { contract.resolve_all }.not_to raise_error
    end

    it "does not raise when all invariants pass" do
      klass = pricing_class
      klass.invariant(:total_pos) { |total:, **| total >= 0 }
      contract = klass.new(price: 10.0, quantity: 5)
      expect { contract.resolve_all }.not_to raise_error
    end

    it "raises InvariantError when an invariant is violated" do
      klass = pricing_class
      klass.invariant(:total_pos) { |total:, **| total >= 0 }
      contract = klass.new(price: -5.0, quantity: 3)
      expect { contract.resolve_all }
        .to raise_error(Igniter::InvariantError, /invariant/)
    end

    it "includes all violated invariant names in the error" do
      klass = pricing_class
      klass.invariant(:pos)      { |total:, **| total >= 0 }
      klass.invariant(:non_zero) { |total:, **| total != 0 }
      contract = klass.new(price: 0.0, quantity: 5)  # total = 0
      error = nil
      begin
        contract.resolve_all
      rescue Igniter::InvariantError => e
        error = e
      end
      expect(error.violations.map(&:name)).to include(:non_zero)
    end

    it "reports multiple violations in a single error" do
      klass = pricing_class
      klass.invariant(:pos)      { |total:, **| total >= 0 }
      klass.invariant(:gt_100)   { |total:, **| total > 100 }
      contract = klass.new(price: -5.0, quantity: 3)   # total = -15
      error = nil
      begin
        contract.resolve_all
      rescue Igniter::InvariantError => e
        error = e
      end
      expect(error.violations.size).to eq(2)
    end

    it "suppresses the auto-raise when :igniter_skip_invariants is set" do
      klass = pricing_class
      klass.invariant(:pos) { |total:, **| total >= 0 }
      contract = klass.new(price: -5.0, quantity: 3)
      Thread.current[:igniter_skip_invariants] = true
      expect { contract.resolve_all }.not_to raise_error
      Thread.current[:igniter_skip_invariants] = false
    end
  end

  # ── check_invariants (manual, non-raising) ───────────────────────────────────

  describe "#check_invariants" do
    it "returns an empty array when no invariants are declared" do
      contract = pricing_class.new(price: 10.0, quantity: 2)
      Thread.current[:igniter_skip_invariants] = true
      contract.resolve_all
      Thread.current[:igniter_skip_invariants] = false
      expect(contract.check_invariants).to eq([])
    end

    it "returns an empty array when all invariants pass" do
      klass = pricing_class
      klass.invariant(:pos) { |total:, **| total >= 0 }
      contract = klass.new(price: 10.0, quantity: 2)
      contract.resolve_all
      expect(contract.check_invariants).to eq([])
    end

    it "returns violations without raising" do
      klass = pricing_class
      klass.invariant(:pos) { |total:, **| total >= 0 }
      contract = klass.new(price: -5.0, quantity: 3)
      Thread.current[:igniter_skip_invariants] = true
      contract.resolve_all
      Thread.current[:igniter_skip_invariants] = false
      violations = contract.check_invariants
      expect(violations.size).to eq(1)
      expect(violations.first.name).to eq(:pos)
    end

    it "only exposes declared output values to the invariant block" do
      # intermediate nodes (subtotal, discount) are not outputs in pricing_class
      klass = pricing_class
      received_keys = []
      klass.invariant(:spy) do |**kwargs|
        received_keys = kwargs.keys
        true
      end
      contract = klass.new(price: 10.0, quantity: 2)
      contract.resolve_all
      expect(received_keys).to eq([:total])
      expect(received_keys).not_to include(:price, :quantity)
    end

    it "exposes multiple output values when contract has multiple outputs" do
      klass = multi_output_class
      received_keys = []
      klass.invariant(:spy) do |**kwargs|
        received_keys = kwargs.keys.sort
        true
      end
      contract = klass.new(price: 20.0, quantity: 5)
      contract.resolve_all
      expect(received_keys).to match_array(%i[total subtotal discount])
    end
  end

  # ── PropertyTesting::Generators ──────────────────────────────────────────────

  describe Igniter::PropertyTesting::Generators do
    describe ".integer" do
      it "returns values within the range" do
        gen = described_class.integer(min: 1, max: 5)
        100.times { expect(gen.call).to be_between(1, 5) }
      end
    end

    describe ".positive_integer" do
      it "returns values >= 1" do
        gen = described_class.positive_integer(max: 10)
        100.times { expect(gen.call).to be >= 1 }
      end
    end

    describe ".float" do
      it "returns values within the range" do
        gen = described_class.float(0.0..10.0)
        100.times { expect(gen.call).to be_between(0.0, 10.0) }
      end

      it "defaults to 0.0..1.0" do
        gen = described_class.float
        100.times { expect(gen.call).to be_between(0.0, 1.0) }
      end
    end

    describe ".string" do
      it "returns a string" do
        expect(described_class.string.call).to be_a(String)
      end

      it "respects a fixed length" do
        gen = described_class.string(length: 5)
        expect(gen.call.length).to eq(5)
      end

      it "respects a length range" do
        gen = described_class.string(length: 3..7)
        100.times { expect(gen.call.length).to be_between(3, 7) }
      end

      it "supports :alphanumeric charset" do
        gen = described_class.string(charset: :alphanumeric)
        expect(gen.call).to match(/\A[a-zA-Z0-9]+\z/)
      end

      it "supports :hex charset" do
        gen = described_class.string(charset: :hex, length: 8)
        expect(gen.call).to match(/\A[0-9a-f]+\z/)
      end

      it "raises on unknown charset" do
        expect { described_class.string(charset: :unknown).call }
          .to raise_error(ArgumentError)
      end
    end

    describe ".one_of" do
      it "returns one of the provided values" do
        gen = described_class.one_of(:a, :b, :c)
        100.times { expect([:a, :b, :c]).to include(gen.call) }
      end

      it "raises when no values provided" do
        expect { described_class.one_of }.to raise_error(ArgumentError)
      end
    end

    describe ".array" do
      it "returns an Array" do
        gen = described_class.array(described_class.integer)
        expect(gen.call).to be_an(Array)
      end

      it "respects a fixed size" do
        gen = described_class.array(described_class.integer, size: 3)
        expect(gen.call.length).to eq(3)
      end
    end

    describe ".boolean" do
      it "returns only true or false" do
        gen = described_class.boolean
        100.times { expect([true, false]).to include(gen.call) }
      end
    end

    describe ".nullable" do
      it "can return nil" do
        gen = described_class.nullable(described_class.integer(min: 1, max: 1), null_rate: 1.0)
        expect(gen.call).to be_nil
      end

      it "returns non-nil when null_rate is 0" do
        gen = described_class.nullable(described_class.integer(min: 5, max: 5), null_rate: 0.0)
        expect(gen.call).to eq(5)
      end
    end

    describe ".hash_of" do
      it "returns a Hash with the specified keys" do
        gen = described_class.hash_of(
          a: described_class.integer(min: 1, max: 1),
          b: described_class.boolean
        )
        result = gen.call
        expect(result).to have_key(:a)
        expect(result).to have_key(:b)
      end
    end

    describe ".constant" do
      it "always returns the same value" do
        gen = described_class.constant("hello")
        10.times { expect(gen.call).to eq("hello") }
      end
    end
  end

  # ── PropertyTesting::Run ─────────────────────────────────────────────────────

  describe Igniter::PropertyTesting::Run do
    let(:inputs) { { price: 10.0, quantity: 2 } }

    it "is passed when no error and no violations" do
      run = described_class.new(run_number: 1, inputs: inputs)
      expect(run).to be_passed
      expect(run).not_to be_failed
    end

    it "is failed when there is an execution_error" do
      run = described_class.new(run_number: 1, inputs: inputs, execution_error: RuntimeError.new("bang"))
      expect(run).to be_failed
      expect(run.failure_type).to eq(:execution_error)
      expect(run.failure_message).to eq("bang")
    end

    it "is failed when there are violations" do
      v   = Igniter::InvariantViolation.new(name: :pos, passed: false)
      run = described_class.new(run_number: 1, inputs: inputs, violations: [v])
      expect(run).to be_failed
      expect(run.failure_type).to eq(:invariant_violation)
      expect(run.failure_message).to include(":pos violated")
    end

    it "freezes inputs" do
      run = described_class.new(run_number: 1, inputs: inputs)
      expect(run.inputs).to be_frozen
    end

    it "stores run_number" do
      run = described_class.new(run_number: 42, inputs: inputs)
      expect(run.run_number).to eq(42)
    end

    it "failure_type is nil for passing run" do
      run = described_class.new(run_number: 1, inputs: inputs)
      expect(run.failure_type).to be_nil
    end
  end

  # ── PropertyTesting::Result ──────────────────────────────────────────────────

  describe Igniter::PropertyTesting::Result do
    let(:pass_run) { Igniter::PropertyTesting::Run.new(run_number: 1, inputs: {}) }
    let(:fail_run) do
      Igniter::PropertyTesting::Run.new(
        run_number: 2, inputs: {}, execution_error: RuntimeError.new("boom")
      )
    end

    it "passed? is true when all runs pass" do
      result = described_class.new(
        contract_class: Igniter::Contract, total_runs: 1, runs: [pass_run]
      )
      expect(result).to be_passed
    end

    it "passed? is false when any run fails" do
      result = described_class.new(
        contract_class: Igniter::Contract, total_runs: 2, runs: [pass_run, fail_run]
      )
      expect(result).not_to be_passed
    end

    it "failed_runs returns only failing runs" do
      result = described_class.new(
        contract_class: Igniter::Contract, total_runs: 2, runs: [pass_run, fail_run]
      )
      expect(result.failed_runs).to eq([fail_run])
    end

    it "passed_runs returns only passing runs" do
      result = described_class.new(
        contract_class: Igniter::Contract, total_runs: 2, runs: [pass_run, fail_run]
      )
      expect(result.passed_runs).to eq([pass_run])
    end

    it "counterexample is nil when all pass" do
      result = described_class.new(
        contract_class: Igniter::Contract, total_runs: 1, runs: [pass_run]
      )
      expect(result.counterexample).to be_nil
    end

    it "counterexample returns the first failing run" do
      result = described_class.new(
        contract_class: Igniter::Contract, total_runs: 2, runs: [pass_run, fail_run]
      )
      expect(result.counterexample).to eq(fail_run)
    end

    it "to_h includes contract name, counts, and counterexample" do
      result = described_class.new(
        contract_class: Igniter::Contract, total_runs: 2, runs: [pass_run, fail_run]
      )
      h = result.to_h
      expect(h[:total_runs]).to eq(2)
      expect(h[:passed]).to eq(1)
      expect(h[:failed]).to eq(1)
      expect(h[:counterexample]).not_to be_nil
    end
  end

  # ── property_test class method ────────────────────────────────────────────────

  describe ".property_test" do
    it "returns a Result" do
      klass = pricing_class
      klass.invariant(:pos) { |total:, **| total >= 0 }
      result = klass.property_test(
        generators: { price: G.float(1.0..10.0), quantity: G.positive_integer(max: 5) },
        runs: 10,
        seed: 1
      )
      expect(result).to be_a(Igniter::PropertyTesting::Result)
    end

    it "passed? is true when invariants always hold" do
      klass = pricing_class
      klass.invariant(:pos) { |total:, **| total >= 0 }
      result = klass.property_test(
        generators: { price: G.float(0.0..100.0), quantity: G.positive_integer(max: 10) },
        runs: 50,
        seed: 42
      )
      expect(result).to be_passed
    end

    it "finds a counterexample when an invariant can be violated" do
      klass = pricing_class
      klass.invariant(:pos) { |total:, **| total >= 0 }
      result = klass.property_test(
        generators: { price: G.float(-50.0..50.0), quantity: G.positive_integer(max: 5) },
        runs: 100,
        seed: 7
      )
      # With negative prices in range, some runs will violate
      expect(result).not_to be_passed
      expect(result.counterexample).not_to be_nil
      expect(result.counterexample.failure_type).to eq(:invariant_violation)
    end

    it "captures execution errors as failed runs without raising" do
      klass = Class.new(Igniter::Contract) do
        define do
          input  :value
          compute :result, depends_on: :value do |value:|
            raise ArgumentError, "must be > 0" if value <= 0
            value * 2
          end
          output :result
        end
        invariant(:pos) { |result:, **| result > 0 }
      end
      result = klass.property_test(
        generators: { value: G.integer(min: -5, max: 5) },
        runs: 50,
        seed: 3
      )
      error_runs = result.failed_runs.select { |r| r.failure_type == :execution_error }
      expect(error_runs).not_to be_empty
    end

    it "is deterministic with a fixed seed" do
      klass = pricing_class
      klass.invariant(:pos) { |total:, **| total >= 0 }
      gens   = { price: G.float(-10.0..10.0), quantity: G.positive_integer(max: 5) }
      result1 = klass.property_test(generators: gens, runs: 20, seed: 99)
      result2 = klass.property_test(generators: gens, runs: 20, seed: 99)
      expect(result1.failed_runs.map(&:inputs)).to eq(result2.failed_runs.map(&:inputs))
    end

    it "total_runs reflects the requested count" do
      klass  = pricing_class
      result = klass.property_test(
        generators: { price: G.constant(1.0), quantity: G.constant(1) },
        runs: 17,
        seed: 1
      )
      expect(result.total_runs).to eq(17)
      expect(result.runs.size).to eq(17)
    end

    it "works without invariants (only captures execution errors)" do
      klass = Class.new(Igniter::Contract) do
        define do
          input  :value
          compute :result, depends_on: :value do |value:|
            raise "bad" if value == 0
            value
          end
          output :result
        end
      end
      result = klass.property_test(
        generators: { value: G.integer(min: -5, max: 5) },
        runs: 30,
        seed: 5
      )
      expect(result).to be_a(Igniter::PropertyTesting::Result)
    end
  end

  # ── explain / formatter ───────────────────────────────────────────────────────

  describe "#explain" do
    it "includes the contract name" do
      klass = pricing_class
      klass.invariant(:pos) { |total:, **| total >= 0 }
      result = klass.property_test(
        generators: { price: G.constant(1.0), quantity: G.constant(1) },
        runs: 5,
        seed: 1
      )
      expect(result.explain).to include("PropertyTest:")
    end

    it "includes run counts" do
      klass = pricing_class
      result = klass.property_test(
        generators: { price: G.constant(1.0), quantity: G.constant(1) },
        runs: 10,
        seed: 1
      )
      expect(result.explain).to include("Runs: 10")
    end

    it "mentions counterexample when there is one" do
      klass = pricing_class
      klass.invariant(:pos) { |total:, **| total >= 0 }
      result = klass.property_test(
        generators: { price: G.float(-10.0..0.0), quantity: G.positive_integer(max: 3) },
        runs: 20,
        seed: 1
      )
      expect(result.explain).to include("COUNTEREXAMPLE")
    end

    it "shows PASS label when all runs pass" do
      klass = pricing_class
      klass.invariant(:pos) { |total:, **| total >= 0 }
      result = klass.property_test(
        generators: { price: G.float(0.0..10.0), quantity: G.positive_integer(max: 5) },
        runs: 10,
        seed: 1
      )
      expect(result.explain).to include("[PASS]")
    end

    it "shows FAIL label when any run fails" do
      klass = pricing_class
      klass.invariant(:pos) { |total:, **| total >= 0 }
      result = klass.property_test(
        generators: { price: G.float(-10.0..0.0), quantity: G.positive_integer(max: 3) },
        runs: 10,
        seed: 1
      )
      expect(result.explain).to include("[FAIL]")
    end
  end
end
