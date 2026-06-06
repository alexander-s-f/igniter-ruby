# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter auditing" do
  let(:contract_class) do
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
      end
    end
  end

  it "collects runtime events in an audit timeline" do
    contract = contract_class.new(order_total: 100, country: "UA")

    contract.result.gross_total
    contract.update_inputs(order_total: 150)
    contract.result.gross_total

    snapshot = contract.audit_snapshot

    expect(snapshot[:graph]).to eq(contract.execution.compiled_graph.name)
    expect(snapshot[:event_count]).to be > 0
    expect(snapshot[:events].map { |event| event[:type] }).to include(:node_started, :node_succeeded, :input_updated, :node_invalidated)
    expect(snapshot[:states][:gross_total]).to include(
      status: :succeeded,
      value: 180.0
    )
  end

  it "includes stable event identifiers in the timeline" do
    contract = contract_class.new(order_total: 100, country: "UA")

    contract.result.gross_total

    event_ids = contract.audit.events.map(&:event_id)
    expect(event_ids).not_to be_empty
    expect(event_ids.uniq).to eq(event_ids)
  end

  it "includes node identifiers in serialized audit events" do
    contract = contract_class.new(order_total: 100, country: "UA")

    contract.result.gross_total

    event = contract.audit_snapshot[:events].find do |entry|
      entry[:node_name] == :gross_total && entry[:type] == :node_succeeded
    end

    expect(event[:node_id]).to eq(contract.execution.compiled_graph.fetch_node(:gross_total).id)
  end

  it "captures child execution snapshots for composition nodes" do
    pricing_contract = contract_class

    checkout_contract = Class.new(Igniter::Contract) do
      define do
        input :order_total
        input :country

        compose :pricing, contract: pricing_contract, inputs: {
          order_total: :order_total,
          country: :country
        }

        output :pricing
      end
    end

    contract = checkout_contract.new(order_total: 100, country: "UA")
    contract.result.pricing.gross_total

    snapshot = contract.audit_snapshot
    child = snapshot[:children].first

    expect(child[:node_name]).to eq(:pricing)
    expect(child[:snapshot][:graph]).to eq(pricing_contract.graph.name)
    expect(child[:snapshot][:states][:gross_total][:value]).to eq(120.0)
  end

  it "captures collection item events in the audit timeline" do
    technician_contract = Class.new(Igniter::Contract) do
      define do
        input :technician_id

        compute :summary, with: :technician_id do |technician_id:|
          raise "inactive" if technician_id == 2

          technician_id
        end

        output :summary
      end
    end

    batch_contract = Class.new(Igniter::Contract) do
      define do
        input :technician_inputs, type: :array

        collection :technicians, with: :technician_inputs, each: technician_contract, key: :technician_id, mode: :collect

        output :technicians
      end
    end

    contract = batch_contract.new(technician_inputs: [
      { technician_id: 1 },
      { technician_id: 2 }
    ])

    contract.result.technicians

    snapshot = contract.audit_snapshot
    item_events = snapshot[:events].select { |event| event[:type].to_s.start_with?("collection_item_") }

    expect(item_events.map { |event| event[:type] }).to include(
      :collection_item_started,
      :collection_item_succeeded,
      :collection_item_failed
    )
    expect(item_events.find { |event| event[:type] == :collection_item_failed }[:payload]).to include(
      item_key: 2,
      error_type: "Igniter::ResolutionError"
    )
  end
end
