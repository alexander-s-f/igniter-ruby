# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter public API" do
  it "compiles an anonymous graph via Igniter.compile" do
    graph = Igniter.compile do
      input :order_total
      compute :gross_total, depends_on: [:order_total] do |order_total:|
        order_total * 1.2
      end
      output :gross_total
    end

    expect(graph).to be_a(Igniter::Compiler::CompiledGraph)
    expect(graph.to_h).to include(
      name: "AnonymousContract",
      resolution_order: %i[order_total gross_total]
    )
  end

  it "exposes the compiled graph on the contract class" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :country
        compute :vat_rate, depends_on: [:country] do |country:|
          country == "UA" ? 0.2 : 0.0
        end
        output :vat_rate
      end
    end

    expect(contract_class.graph.to_h[:outputs]).to eq(
      [{ name: :vat_rate, path: "output.vat_rate", source: :vat_rate }]
    )
  end

  it "uses a stable fallback graph name for anonymous contract classes" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :order_total
        output :order_total
      end
    end

    expect(contract_class.graph.name).to eq("AnonymousContract")
  end

  it "indexes compiled nodes by id and path" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :order_total
        output :order_total
      end
    end

    node = contract_class.graph.fetch_node(:order_total)

    expect(contract_class.graph.fetch_node_by_id(node.id)).to eq(node)
    expect(contract_class.graph.fetch_node_by_path(node.path)).to eq(node)
  end

  it "serializes runtime objects into machine-readable hashes" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :order_total
        output :order_total
      end
    end

    contract = contract_class.new(order_total: 100)
    event = contract.tap { |instance| instance.result.order_total }.events.first

    expect(event.to_h).to include(
      event_id: event.event_id,
      execution_id: contract.execution.events.execution_id
    )
    expect(event.as_json[:timestamp]).to be_a(String)

    expect(contract.execution.to_h).to include(
      graph: "AnonymousContract",
      execution_id: contract.execution.events.execution_id,
      success: true,
      failed: false
    )
    expect(contract.execution.as_json[:events]).to all(include(:event_id, :type))

    expect(contract.result.as_json).to include(
      graph: "AnonymousContract",
      execution_id: contract.execution.events.execution_id,
      outputs: { order_total: 100 },
      success: true,
      failed: false
    )
  end
end
