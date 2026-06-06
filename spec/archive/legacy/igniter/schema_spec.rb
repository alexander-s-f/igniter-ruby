# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter schema builder" do
  around do |example|
    Igniter.executor_registry.clear
    example.run
    Igniter.executor_registry.clear
  end

  class SchemaMultiplyExecutor < Igniter::Executor
    executor_key "pricing.schema_multiply"
    label "Schema multiply"
    category :pricing
    summary "Multiplies two numeric values"

    input :order_total, type: :numeric
    input :multiplier, type: :numeric

    def call(order_total:, multiplier:)
      order_total * multiplier
    end
  end

  it "builds a contract from hash schema using executor registry" do
    Igniter.register_executor("pricing.schema_multiply", SchemaMultiplyExecutor)

    contract_class = Class.new(Igniter::Contract) do
      define_schema(
        name: "SchemaPricingContract",
        inputs: [
          { name: :order_total, type: :numeric },
          { name: :multiplier, type: :numeric, default: 1.2 }
        ],
        computes: [
          {
            name: :gross_total,
            depends_on: %i[order_total multiplier],
            executor: "pricing.schema_multiply"
          }
        ],
        outputs: [
          { name: :gross_total }
        ]
      )
    end

    contract = contract_class.new(order_total: 100)

    expect(contract.result.gross_total).to eq(120.0)
    expect(contract.class.graph.to_schema[:computes].first[:executor]).to eq("pricing.schema_multiply")
  end
end
