# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter quick start examples" do
  let(:price_contract) do
    Class.new(Igniter::Contract) do
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
  end

  it "demonstrates the basic quick start flow" do
    contract = price_contract.new(order_total: 100, country: "UA")

    expect(contract.result.gross_total).to eq(120.0)

    contract.update_inputs(order_total: 150)
    expect(contract.result.gross_total).to eq(180.0)
  end

  it "demonstrates composition for a nested contract" do
    pricing = price_contract

    checkout_contract = Class.new(Igniter::Contract) do
      define do
        input :order_total, type: :numeric
        input :country, type: :string

        compose :pricing, contract: pricing, inputs: {
          order_total: :order_total,
          country: :country
        }

        output :pricing
      end
    end

    contract = checkout_contract.new(order_total: 100, country: "UA")

    expect(contract.result.pricing.gross_total).to eq(120.0)
    expect(contract.result.to_h).to eq(pricing: { gross_total: 120.0 })
  end

  it "demonstrates diagnostics and machine-readable APIs" do
    contract = price_contract.new(order_total: 100, country: "UA")
    contract.result.gross_total

    expect(contract.result.as_json[:outputs]).to eq(gross_total: 120.0)
    expect(contract.execution.as_json[:graph]).to eq("AnonymousContract")
    expect(contract.events.map(&:as_json)).not_to be_empty
    expect(contract.diagnostics.to_h[:status]).to eq(:succeeded)
    expect(contract.diagnostics_text).to include("Status: succeeded")
    expect(contract.diagnostics_markdown).to include("# Diagnostics AnonymousContract")
  end
end
