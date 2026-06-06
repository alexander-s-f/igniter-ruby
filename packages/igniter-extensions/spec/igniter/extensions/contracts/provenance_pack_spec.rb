# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::ProvenancePack do
  it "builds lineage for contracts execution results through the public contracts surface" do
    environment = Igniter::Contracts.with(described_class)

    compiled = environment.compile do
      input :price
      input :quantity

      compute :subtotal, depends_on: %i[price quantity] do |price:, quantity:|
        price * quantity
      end

      compute :tax, depends_on: [:subtotal] do |subtotal:|
        subtotal * 0.1
      end

      compute :total, depends_on: %i[subtotal tax] do |subtotal:, tax:|
        subtotal + tax
      end

      output :total
    end

    result = environment.execute(compiled, inputs: { price: 50.0, quantity: 4 })
    lineage = described_class.lineage(result, :total)

    expect(lineage.value).to eq(220.0)
    expect(lineage.contributing_inputs).to eq(price: 50.0, quantity: 4)
    expect(lineage.sensitive_to?(:price)).to eq(true)
    expect(lineage.sensitive_to?(:discount)).to eq(false)
    expect(lineage.path_to(:price)).to eq(%i[total subtotal price])
    expect(lineage.explain).to include("total = 220.0  [compute]")
  end

  it "contributes provenance summaries through diagnostics when the pack is installed" do
    environment = Igniter::Contracts.with(described_class)

    result = environment.run(inputs: { amount: 10 }) do
      input :amount
      compute :tax, depends_on: [:amount] do |amount:|
        amount * 0.2
      end
      output :tax
    end

    report = environment.diagnose(result)

    expect(report.section(:provenance)).to eq(
      outputs: {
        tax: {
          value: 2.0,
          contributing_inputs: { amount: 10 }
        }
      }
    )
  end
end
