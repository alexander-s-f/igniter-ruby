# frozen_string_literal: true

require "spec_helper"
require "igniter/core"

RSpec.describe Igniter::StreamLoop do
  let(:simple_contract) do
    Class.new(Igniter::Contract) do
      define do
        input :value, type: :numeric
        compute :doubled, depends_on: :value do |value:|
          value * 2
        end
        output :doubled
      end
    end
  end

  let(:error_contract) do
    Class.new(Igniter::Contract) do
      define do
        input :value, type: :numeric
        compute :result, depends_on: :value do |value:|
          raise "deliberate error" if value < 0

          value
        end
        output :result
      end
    end
  end

  # ── Basic lifecycle ───────────────────────────────────────────────────────────

  describe "#start / #stop" do
    it "starts and stops cleanly" do
      stream = described_class.new(
        contract: simple_contract,
        tick_interval: 0.1,
        inputs: { value: 5.0 }
      )
      stream.start
      expect(stream.alive?).to be true
      stream.stop
      expect(stream.alive?).to be false
    end
  end

  describe "#alive?" do
    it "is false before start" do
      stream = described_class.new(contract: simple_contract, inputs: { value: 1.0 })
      expect(stream.alive?).to be false
    end
  end

  # ── on_result callback ────────────────────────────────────────────────────────

  describe "on_result" do
    it "receives resolved contract results on each tick" do
      results = []
      stream = described_class.new(
        contract: simple_contract,
        tick_interval: 0.05,
        inputs: { value: 3.0 },
        on_result: ->(r) { results << r.doubled }
      )
      stream.start
      sleep(0.2)
      stream.stop
      expect(results).not_to be_empty
      expect(results).to all(eq(6.0))
    end
  end

  # ── on_error callback ─────────────────────────────────────────────────────────

  describe "on_error" do
    it "receives errors from failing ticks without stopping the loop" do
      errors = []
      stream = described_class.new(
        contract: error_contract,
        tick_interval: 0.05,
        inputs: { value: -1.0 },
        on_result: ->(_) {},
        on_error: ->(e) { errors << e }
      )
      stream.start
      sleep(0.2)
      stream.stop
      expect(errors).not_to be_empty
      expect(errors.first.message).to include("deliberate error")
    end
  end

  # ── update_inputs ─────────────────────────────────────────────────────────────

  describe "#update_inputs" do
    it "applies new inputs on subsequent ticks" do
      results = []
      stream = described_class.new(
        contract: simple_contract,
        tick_interval: 0.05,
        inputs: { value: 1.0 },
        on_result: ->(r) { results << r.doubled }
      )
      stream.start
      sleep(0.15)                       # a few ticks at value=1 → doubled=2
      stream.update_inputs(value: 10.0) # switch to value=10 → doubled=20
      sleep(0.15)
      stream.stop

      expect(results).to include(2.0)
      expect(results).to include(20.0)
    end

    it "returns self (chainable)" do
      stream = described_class.new(contract: simple_contract, inputs: { value: 1.0 })
      expect(stream.update_inputs(value: 2.0)).to be(stream)
    end
  end

  # ── type validation ───────────────────────────────────────────────────────────

  describe "contract type validation" do
    let(:strict_contract) do
      Class.new(Igniter::Contract) do
        define do
          input :count, type: :numeric
          compute :result, depends_on: :count do |count:|
            count * 10
          end
          output :result
        end
      end
    end

    it "delivers results when inputs satisfy contract types" do
      results = []
      stream = described_class.new(
        contract: strict_contract,
        tick_interval: 0.05,
        inputs: { count: 3.0 },
        on_result: ->(r) { results << r.result }
      )
      stream.start
      sleep(0.15)
      stream.stop
      expect(results).to all(eq(30.0))
    end
  end
end
