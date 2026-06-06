# frozen_string_literal: true

require "spec_helper"
require "igniter/core/temporal"

RSpec.describe Igniter::Temporal do
  # ─── Module inclusion ─────────────────────────────────────────────────────

  describe ".temporal?" do
    it "returns true for temporal contracts" do
      klass = Class.new(Igniter::Contract) do
        include Igniter::Temporal
        define { input :x; output :x }
      end
      expect(klass.temporal?).to be true
    end

    it "returns nil/false for plain contracts" do
      klass = Class.new(Igniter::Contract) do
        define { input :x; output :x }
      end
      expect(klass.respond_to?(:temporal?)).to be false
    end
  end

  # ─── as_of injection ──────────────────────────────────────────────────────

  describe "as_of input injection" do
    let(:contract_class) do
      Class.new(Igniter::Contract) do
        include Igniter::Temporal

        define do
          input :country
          compute :label, depends_on: %i[country as_of] do |country:, as_of:|
            "#{country} @ #{as_of.strftime("%Y")}"
          end
          output :label
        end
      end
    end

    it "adds as_of as an input node in the graph" do
      input_names = contract_class.compiled_graph.nodes
                                  .select { |n| n.kind == :input }
                                  .map(&:name)
      expect(input_names).to include(:as_of)
    end

    it "defaults as_of to approximately Time.now" do
      before = Time.now
      c = contract_class.new(country: "UA")
      c.resolve_all
      after = Time.now

      as_of_state = c.execution.cache.fetch(:as_of)
      expect(as_of_state.value).to be_between(before, after)
    end

    it "accepts an explicit as_of value" do
      t = Time.new(2024, 1, 1, 12, 0, 0)
      c = contract_class.new(country: "UA", as_of: t)
      c.resolve_all
      expect(c.result.label).to eq("UA @ 2024")
    end
  end

  # ─── temporal_compute DSL ────────────────────────────────────────────────

  describe "temporal_compute DSL" do
    let(:contract_class) do
      Class.new(Igniter::Contract) do
        include Igniter::Temporal

        define do
          input :amount
          # temporal_compute automatically adds :as_of to depends_on
          temporal_compute :result, depends_on: :amount do |amount:, as_of:|
            amount * (as_of.year >= 2025 ? 1.2 : 1.0)
          end
          output :result
        end
      end
    end

    it "passes as_of to the block" do
      t = Time.new(2025, 6, 1)
      c = contract_class.new(amount: 100, as_of: t)
      c.resolve_all
      expect(c.result.result).to eq(120.0)
    end

    it "uses the pre-2025 factor for an older timestamp" do
      t = Time.new(2024, 1, 1)
      c = contract_class.new(amount: 100, as_of: t)
      c.resolve_all
      expect(c.result.result).to eq(100.0)
    end
  end

  # ─── Reproducibility ─────────────────────────────────────────────────────

  describe "historical reproduction" do
    let(:rate_contract) do
      rates = { "UA" => { 2024 => 0.20, 2025 => 0.22 } }.freeze
      Class.new(Igniter::Contract) do
        include Igniter::Temporal

        define do
          input :country
          temporal_compute :rate, depends_on: :country do |country:, as_of:|
            rates.dig(country, as_of.year) || 0.0
          end
          output :rate
        end
      end
    end

    it "reproduces the 2024 rate when given the historical as_of" do
      c = rate_contract.new(country: "UA", as_of: Time.new(2024, 6, 1))
      c.resolve_all
      expect(c.result.rate).to eq(0.20)
    end

    it "produces the 2025 rate with a current timestamp" do
      c = rate_contract.new(country: "UA", as_of: Time.new(2025, 6, 1))
      c.resolve_all
      expect(c.result.rate).to eq(0.22)
    end
  end

  # ─── TemporalExecutor ────────────────────────────────────────────────────

  describe Igniter::Temporal::Executor do
    it "is a subclass of Igniter::Executor" do
      expect(Igniter::Temporal::Executor).to be < Igniter::Executor
    end

    it "can be used as a callable in a temporal contract" do
      executor_class = Class.new(Igniter::Temporal::Executor) do
        def call(amount:, as_of:)
          as_of.year >= 2025 ? amount * 1.1 : amount
        end
      end

      ec = executor_class
      contract = Class.new(Igniter::Contract) do
        include Igniter::Temporal
        define do
          input :amount
          temporal_compute :result, depends_on: :amount, call: ec
          output :result
        end
      end

      c = contract.new(amount: 100, as_of: Time.new(2025, 1, 1))
      c.resolve_all
      expect(c.result.result).to be_within(0.001).of(110.0)
    end
  end
end
