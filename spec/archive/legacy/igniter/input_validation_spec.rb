# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter input validation" do
  let(:contract_class) do
    Class.new(Igniter::Contract) do
      define do
        input :order_total, type: :numeric
        input :country, type: :string
        input :coupon, type: :string, required: false
        input :vat_rate, type: :numeric, default: 0.2

        compute :gross_total, depends_on: %i[order_total vat_rate] do |order_total:, vat_rate:|
          order_total * (1 + vat_rate)
        end

        output :gross_total
        output :vat_rate
      end
    end
  end

  it "applies default input values" do
    contract = contract_class.new(order_total: 100, country: "UA")

    expect(contract.result.vat_rate).to eq(0.2)
    expect(contract.result.gross_total).to eq(120.0)
  end

  it "allows optional nil inputs" do
    contract = contract_class.new(order_total: 100, country: "UA", coupon: nil)

    expect(contract.result.gross_total).to eq(120.0)
  end

  it "raises on invalid initial input types" do
    expect do
      contract_class.new(order_total: "100", country: "UA")
    end.to raise_error(Igniter::InputError, /order_total.*numeric/i)
  end

  it "raises on unknown initial inputs" do
    expect do
      contract_class.new(order_total: 100, country: "UA", region: "EU")
    end.to raise_error(Igniter::InputError, /Unknown inputs: region/)
  end

  it "raises when a required input is missing at resolution time" do
    contract = contract_class.new(country: "UA")

    expect do
      contract.result.gross_total
    end.to raise_error(Igniter::InputError, /Missing required input: order_total/)
  end

  it "attaches graph and node context to input errors" do
    contract = contract_class.new(country: "UA")

    expect do
      contract.result.gross_total
    end.to raise_error(Igniter::InputError) { |error|
      expect(error.graph).to eq("AnonymousContract")
      expect(error.node_name).to eq(:order_total)
      expect(error.node_path).to eq("order_total")
      expect(error.message).to include("graph=AnonymousContract")
      expect(error.message).to include("node=order_total")
    }
  end

  it "validates updated input types" do
    contract = contract_class.new(order_total: 100, country: "UA")

    expect do
      contract.update_inputs(order_total: "150")
    end.to raise_error(Igniter::InputError, /order_total.*numeric/i)
  end

  it "accepts boolean typed inputs" do
    boolean_contract = Class.new(Igniter::Contract) do
      define do
        input :eligible, type: :boolean
        output :eligible
      end
    end

    expect(boolean_contract.new(eligible: true).result.eligible).to eq(true)
    expect do
      boolean_contract.new(eligible: "true")
    end.to raise_error(Igniter::InputError, /eligible.*boolean/i)
  end
end
