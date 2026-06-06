# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::AggregatePack do
  it "adds count, sum, and avg as external aggregation DSL lowered into compute semantics" do
    environment = Igniter::Contracts.with(described_class)

    compiled = environment.compile do
      input :items
      count :item_count, from: :items
      sum :total, from: :items
      avg :average, from: :items
      output :item_count
      output :total
      output :average
    end
    result = environment.execute(compiled, inputs: { items: [1, 2, 3, 4] })

    expect(environment.profile.dsl_keyword(:count)).to be_a(Igniter::Contracts::DslKeyword)
    expect(environment.profile.supports_node_kind?(:count)).to be(false)
    expect(environment.profile.supports_node_kind?(:sum)).to be(false)
    expect(environment.profile.supports_node_kind?(:avg)).to be(false)
    expect(compiled.operations.map(&:kind)).to eq(%i[input compute compute compute output output output])
    expect(result.output(:item_count)).to eq(4)
    expect(result.output(:total)).to eq(10)
    expect(result.output(:average)).to eq(2.5)
  end

  it "composes with lookup pack to aggregate nested data" do
    environment = Igniter::Contracts.with(
      Igniter::Extensions::Contracts::LookupPack,
      described_class
    )

    result = environment.run(inputs: {
                               order: {
                                 items: [
                                   { amount: 10 },
                                   { amount: 20 },
                                   { amount: 30 }
                                 ]
                               }
                             }) do
      input :order
      lookup :items, from: :order, key: :items
      count :item_count, from: :items
      sum :total_amount, from: :items, using: :amount
      avg :average_amount, from: :items, using: :amount
      output :item_count
      output :total_amount
      output :average_amount
    end

    expect(result.output(:item_count)).to eq(3)
    expect(result.output(:total_amount)).to eq(60)
    expect(result.output(:average_amount)).to eq(20.0)
  end

  it "supports proc-based projections and count predicates" do
    environment = Igniter::Contracts.with(described_class)

    result = environment.run(inputs: {
                               items: [
                                 { amount: 10, taxable: true },
                                 { amount: 20, taxable: false },
                                 { amount: 30, taxable: true }
                               ]
                             }) do
      input :items
      count :taxable_count, from: :items, matching: ->(item) { item.fetch(:taxable) }
      sum :taxable_total, from: :items, using: ->(item) { item.fetch(:taxable) ? item.fetch(:amount) : 0 }
      output :taxable_count
      output :taxable_total
    end

    expect(result.output(:taxable_count)).to eq(2)
    expect(result.output(:taxable_total)).to eq(40)
  end

  it "uses baseline dependency validation when aggregate sources are missing" do
    environment = Igniter::Contracts.with(described_class)

    expect do
      environment.compile do
        sum :total, from: :items
        output :total
      end
    end.to raise_error(Igniter::Contracts::ValidationError) { |error|
      expect(error.findings.map(&:code)).to eq([:missing_compute_dependencies])
      expect(error.findings.first.subjects).to eq([:items])
    }
  end
end
