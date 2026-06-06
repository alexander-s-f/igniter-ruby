# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::DifferentialPack do
  def build_primary_graph(environment)
    environment.compile do
      input :price
      input :quantity

      compute :subtotal, depends_on: %i[price quantity] do |price:, quantity:|
        (price * quantity).round(2)
      end

      compute :tax, depends_on: [:subtotal] do |subtotal:|
        (subtotal * 0.10).round(2)
      end

      compute :total, depends_on: %i[subtotal tax] do |subtotal:, tax:|
        (subtotal + tax).round(2)
      end

      output :subtotal
      output :tax
      output :total
    end
  end

  def build_candidate_graph(environment)
    environment.compile do
      input :price
      input :quantity

      compute :subtotal, depends_on: %i[price quantity] do |price:, quantity:|
        (price * quantity).round(2)
      end

      compute :tax, depends_on: [:subtotal] do |subtotal:|
        (subtotal * 0.15).round(2)
      end

      compute :discount, depends_on: [:subtotal] do |subtotal:|
        subtotal > 100 ? 10.0 : 0.0
      end

      compute :total, depends_on: %i[subtotal tax discount] do |subtotal:, tax:, discount:|
        (subtotal + tax - discount).round(2)
      end

      output :subtotal
      output :tax
      output :discount
      output :total
    end
  end

  it "builds a structured divergence report over two contracts environments" do
    environment = Igniter::Contracts.with(described_class)
    primary_graph = build_primary_graph(environment)
    candidate_graph = build_candidate_graph(environment)

    report = described_class.compare(
      inputs: { price: 50.0, quantity: 3 },
      primary_environment: environment,
      primary_compiled_graph: primary_graph,
      candidate_environment: environment,
      candidate_compiled_graph: candidate_graph,
      primary_name: "PricingV1",
      candidate_name: "PricingV2"
    )

    expect(report.match?).to eq(false)
    expect(report.divergences.map(&:output_name)).to eq(%i[tax total])
    expect(report.divergences.find { |divergence| divergence.output_name == :tax }&.delta).to eq(7.5)
    expect(report.candidate_only).to eq(discount: 10.0)
    expect(report.summary).to include("2 value(s) differ")
    expect(report.explain).to include("Candidate:  PricingV2")
    expect(report.to_h.fetch(:candidate_outputs)).to include(discount: 10.0)
  end

  it "supports tolerance and explicit shadow comparison from an existing primary execution" do
    environment = Igniter::Contracts.with(described_class)
    primary_graph = build_primary_graph(environment)
    candidate_graph = build_candidate_graph(environment)
    primary_result = environment.execute(primary_graph, inputs: { price: 50.0, quantity: 3 })
    divergences = []

    report = described_class.shadow(
      inputs: { price: 50.0, quantity: 3 },
      primary_result: primary_result,
      candidate_environment: environment,
      candidate_compiled_graph: candidate_graph,
      tolerance: 10.0,
      primary_name: "PricingV1",
      candidate_name: "PricingV2",
      on_divergence: ->(value) { divergences << value.summary }
    )

    expect(report.divergences).to be_empty
    expect(report.candidate_only).to eq(discount: 10.0)
    expect(divergences).to eq(["diverged - 1 output(s) only in candidate"])
  end

  it "captures runtime failures from either side without crashing the comparison" do
    environment = Igniter::Contracts.with(described_class)
    primary_graph = build_primary_graph(environment)
    candidate_graph = environment.compile do
      input :price
      input :quantity

      compute :subtotal, depends_on: %i[price quantity] do |price:, quantity:|
        raise "candidate exploded" if quantity == 3

        price * quantity
      end

      output :subtotal
    end

    report = Igniter::Extensions::Contracts.compare_differential(
      inputs: { price: 50.0, quantity: 3 },
      primary_environment: environment,
      primary_compiled_graph: primary_graph,
      candidate_environment: environment,
      candidate_compiled_graph: candidate_graph,
      primary_name: "primary",
      candidate_name: "candidate"
    )

    expect(report.match?).to eq(false)
    expect(report.candidate_error).to include(type: "RuntimeError", message: "candidate exploded")
    expect(report.primary_error).to be_nil
    expect(report.summary).to include("candidate error: candidate exploded")
  end
end
