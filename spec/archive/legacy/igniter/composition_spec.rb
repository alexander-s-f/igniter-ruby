# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter composition" do
  let(:pricing_contract) do
    Class.new(Igniter::Contract) do
      define do
        input :order_total
        input :country

        compute :vat_rate, depends_on: [:country] do |country:|
          country == "UA" ? 0.2 : 0.0
        end

        compute :gross_total, depends_on: %i[order_total vat_rate] do |order_total:, vat_rate:|
          order_total * (1 + vat_rate)
        end

        output :gross_total
        output :vat_rate
      end
    end
  end

  let(:checkout_contract) do
    child_contract = pricing_contract

    Class.new(Igniter::Contract) do
      define do
        input :order_total
        input :country

        compose :pricing, contract: child_contract, inputs: {
          order_total: :order_total,
          country: :country
        }

        output :pricing
      end
    end
  end

  let(:checkout_projection_contract) do
    child_contract = pricing_contract

    Class.new(Igniter::Contract) do
      define do
        input :order_total
        input :country

        compose :pricing, contract: child_contract, inputs: {
          order_total: :order_total,
          country: :country
        }

        output :gross_total, from: "pricing.gross_total"
        output :vat_rate, from: "pricing.vat_rate"
      end
    end
  end

  it "returns a nested result for composition outputs" do
    contract = checkout_contract.new(order_total: 100, country: "UA")

    pricing_result = contract.result.pricing

    expect(pricing_result).to be_a(Igniter::Runtime::Result)
    expect(pricing_result.gross_total).to eq(120.0)
    expect(contract.result.to_h).to eq(
      pricing: {
        gross_total: 120.0,
        vat_rate: 0.2
      }
    )
  end

  it "exports child composition outputs directly without projection compute nodes" do
    contract = checkout_projection_contract.new(order_total: 100, country: "UA")

    expect(contract.result.gross_total).to eq(120.0)
    expect(contract.result.vat_rate).to eq(0.2)
    expect(contract.result.to_h).to eq(
      gross_total: 120.0,
      vat_rate: 0.2
    )
  end

  it "allows downstream composition inputs to depend on exported outputs" do
    pricing = pricing_contract

    pipeline_contract = Class.new(Igniter::Contract) do
      define do
        input :order_total
        input :country

        compose :pricing, contract: pricing, inputs: {
          order_total: :order_total,
          country: :country
        }

        output :gross_total, from: "pricing.gross_total"
        output :vat_rate, from: "pricing.vat_rate"

        compute :summary, depends_on: %i[gross_total vat_rate] do |gross_total:, vat_rate:|
          {
            gross_total: gross_total,
            vat_rate: vat_rate
          }
        end

        output :summary
      end
    end

    contract = pipeline_contract.new(order_total: 100, country: "UA")

    expect(contract.result.summary).to eq(
      gross_total: 120.0,
      vat_rate: 0.2
    )
  end

  it "keeps child execution isolated from parent execution" do
    contract = checkout_contract.new(order_total: 100, country: "UA")

    pricing_result = contract.result.pricing
    child_execution_id = pricing_result.execution.events.execution_id
    parent_execution_id = contract.execution.events.execution_id

    expect(child_execution_id).not_to eq(parent_execution_id)
    expect(contract.events.map(&:path)).to include("pricing")
    expect(contract.events.map(&:path)).not_to include("gross_total")
    expect(pricing_result.execution.events.events.map(&:path)).to include("gross_total")
  end

  it "creates a new child execution after parent invalidation" do
    contract = checkout_contract.new(order_total: 100, country: "UA")

    first_child = contract.result.pricing
    first_execution_id = first_child.execution.events.execution_id

    contract.update_inputs(order_total: 150)
    second_child = contract.result.pricing

    expect(second_child.gross_total).to eq(180.0)
    expect(second_child.execution.events.execution_id).not_to eq(first_execution_id)
  end

  it "fails compilation for unknown child input mappings" do
    child_contract = pricing_contract

    expect do
      Class.new(Igniter::Contract) do
        define do
          input :order_total

          compose :pricing, contract: child_contract, inputs: {
            order_total: :order_total,
            unknown_child_input: :order_total
          }

          output :pricing
        end
      end
    end.to raise_error(Igniter::ValidationError, /maps unknown child inputs: unknown_child_input/i)
  end

  it "fails compilation when required child inputs are not mapped" do
    child_contract = pricing_contract

    expect do
      Class.new(Igniter::Contract) do
        define do
          input :order_total

          compose :pricing, contract: child_contract, inputs: {
            order_total: :order_total
          }

          output :pricing
        end
      end
    end.to raise_error(Igniter::ValidationError, /missing mappings for required child inputs: country/i)
  end

  it "fails compilation for unknown exported child outputs" do
    child_contract = pricing_contract

    expect do
      Class.new(Igniter::Contract) do
        define do
          input :order_total
          input :country

          compose :pricing, contract: child_contract, inputs: {
            order_total: :order_total,
            country: :country
          }

          output :missing_value, from: "pricing.missing_value"
        end
      end
    end.to raise_error(Igniter::ValidationError, /unknown child output 'missing_value'/i)
  end

  it "eagerly resolves child outputs before marking composition as succeeded" do
    contract = checkout_contract.new(order_total: 100, country: "UA")

    pricing_result = contract.result.pricing

    child_event_types = pricing_result.execution.events.events.map(&:type)
    expect(child_event_types).to include(:execution_started, :execution_finished, :node_succeeded)

    pricing_event = contract.events.find { |event| event.type == :node_succeeded && event.path == "pricing" }
    expect(pricing_event.payload).to include(
      child_execution_id: pricing_result.execution.events.execution_id,
      child_graph: pricing_result.execution.compiled_graph.name
    )
  end

  it "fails the parent composition node when child resolution fails" do
    failing_child = Class.new(Igniter::Contract) do
      define do
        input :order_total

        compute :gross_total, depends_on: [:order_total] do |order_total:|
          raise "boom" if order_total > 100

          order_total
        end

        output :gross_total
      end
    end

    parent_contract = Class.new(Igniter::Contract) do
      define do
        input :order_total
        compose :pricing, contract: failing_child, inputs: { order_total: :order_total }
        output :pricing
      end
    end

    contract = parent_contract.new(order_total: 150)

    expect { contract.result.pricing }.to raise_error(Igniter::ResolutionError, /boom/)

    pricing_state = contract.execution.cache.fetch(:pricing)
    expect(pricing_state).to be_failed
    expect(contract.events.map(&:type)).to include(:execution_failed, :node_failed)
  end
end
