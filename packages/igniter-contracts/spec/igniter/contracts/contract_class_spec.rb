# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contract do
  it "keeps the low-level block compile form valid" do
    compiled = Igniter::Contracts.compile do
      input :amount
      output :amount
    end

    result = Igniter::Contracts.execute(compiled, inputs: { amount: 10 })

    expect(result.output(:amount)).to eq(10)
  end

  it "supports the human-facing contract class DSL" do
    price_contract = Class.new(described_class) do
      define do
        input :order_total, type: :numeric
        input :country, type: :string

        compute :vat_rate, depends_on: [:country] do |country:|
          country == "UA" ? 0.2 : 0.0
        end

        compute :gross_total, depends_on: %i[order_total vat_rate] do |order_total:, vat_rate:|
          order_total * (1 + vat_rate)
        end

        output :gross_total
      end
    end

    contract = price_contract.new(order_total: 100, country: "UA")

    expect(contract.result.gross_total).to eq(120.0)
    expect(contract.output(:gross_total)).to eq(120.0)
    expect(contract.outputs.fetch(:gross_total)).to eq(120.0)
    expect(contract).to be_success
    expect(contract).not_to be_failure

    contract.update_inputs(order_total: 150)

    expect(contract.result.gross_total).to eq(180.0)
    expect(contract.to_h).to include(
      inputs: { order_total: 150, country: "UA" },
      outputs: { gross_total: 180.0 },
      success: true
    )
  end

  it "supports compute callables through call:" do
    gross_total_callable = Class.new do
      def self.call(order_total:, country:)
        order_total * (country == "UA" ? 1.2 : 1.0)
      end
    end

    price_contract = Class.new(described_class) do
      define do
        input :order_total
        input :country
        compute :gross_total, depends_on: %i[order_total country], call: gross_total_callable
        output :gross_total
      end
    end

    expect(price_contract.new(order_total: 100, country: "UA").result.gross_total).to eq(120.0)
  end

  it "raises a clear error for unknown result readers" do
    contract_class = Class.new(described_class) do
      define do
        input :amount
        output :amount
      end
    end

    expect do
      contract_class.new(amount: 10).result.missing_amount
    end.to raise_error(KeyError, /unknown contract output missing_amount/)

    expect do
      contract_class.new(amount: 10).result.output(:missing_amount)
    end.to raise_error(KeyError, /unknown contract output missing_amount/)
  end
end
