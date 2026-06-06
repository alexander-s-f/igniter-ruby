# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::InvariantsPack do
  it "builds explicit invariant suites over outputs" do
    suite = described_class.build do
      invariant(:total_non_negative) { |total:, **| total >= 0 }
      invariant(:discount_non_negative) { |discount:, **| discount >= 0 }
    end

    expect(suite.names).to eq(%i[total_non_negative discount_non_negative])
    expect(suite).not_to be_empty
  end

  it "checks execution results without raising" do
    environment = Igniter::Contracts.with(described_class)
    suite = described_class.build do
      invariant(:total_non_negative) { |total:, **| total >= 0 }
    end

    result = environment.run(inputs: { price: -5.0, quantity: 3 }) do
      input :price
      input :quantity
      compute :total, depends_on: %i[price quantity] do |price:, quantity:|
        price * quantity
      end
      output :total
    end

    report = described_class.check(result, invariants: suite)

    expect(report.invalid?).to eq(true)
    expect(report.violations.map(&:name)).to eq([:total_non_negative])
    expect(report.outputs).to eq(total: -15.0)
  end

  it "validates and raises on invariant violations" do
    environment = Igniter::Contracts.with(described_class)
    suite = described_class.build do
      invariant(:total_non_negative) { |total:, **| total >= 0 }
    end

    result = environment.run(inputs: { price: -5.0, quantity: 3 }) do
      input :price
      input :quantity
      compute :total, depends_on: %i[price quantity] do |price:, quantity:|
        price * quantity
      end
      output :total
    end

    expect { described_class.validate!(result, invariants: suite) }
      .to raise_error(Igniter::Extensions::Contracts::Invariants::InvariantError, /total_non_negative/)
  end

  it "runs invariants directly over an environment and verifies multiple cases" do
    environment = Igniter::Contracts.with(described_class)
    suite = described_class.build do
      invariant(:total_non_negative) { |total:, **| total >= 0 }
      invariant(:total_le_subtotal) { |total:, subtotal:, **| total <= subtotal }
    end

    report = described_class.run(environment, inputs: { price: 20.0, quantity: 10 }, invariants: suite) do
      input :price
      input :quantity

      compute :subtotal, depends_on: %i[price quantity] do |price:, quantity:|
        price * quantity
      end

      compute :discount, depends_on: [:subtotal] do |subtotal:|
        subtotal > 100 ? subtotal * 0.1 : 0.0
      end

      compute :total, depends_on: %i[subtotal discount] do |subtotal:, discount:|
        subtotal - discount
      end

      output :total
      output :subtotal
      output :discount
    end

    cases = described_class.verify_cases(
      environment,
      cases: [
        { price: 20.0, quantity: 10 },
        { price: -5.0, quantity: 3 }
      ],
      invariants: suite,
      compiled_graph: report.execution_result.compiled_graph
    )

    expect(report.valid?).to eq(true)
    expect(cases.valid?).to eq(false)
    expect(cases.invalid_cases.length).to eq(1)
  end
end
