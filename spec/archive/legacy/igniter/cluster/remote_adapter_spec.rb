# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe Igniter::Cluster::RemoteAdapter do
  around do |example|
    previous_adapter = Igniter::Runtime.remote_adapter
    Igniter::Runtime.remote_adapter = Igniter::Runtime::RemoteAdapter.new
    Igniter::Cluster::Mesh.reset!
    example.run
    Igniter::Cluster::Mesh.reset!
    Igniter::Runtime.remote_adapter = previous_adapter
  end

  it "installs itself as the runtime remote adapter when explicitly activated" do
    expect(Igniter::Runtime.remote_adapter).to be_a(Igniter::Runtime::RemoteAdapter)

    Igniter::Cluster.activate_remote_adapter!

    expect(Igniter::Runtime.remote_adapter).to be_a(described_class)
  end

  it "publishes pending routing reports into mesh config when capability routing defers" do
    adapter = described_class.new
    node = Igniter::Model::RemoteNode.new(
      id: "test:2",
      name: :order_result,
      contract_name: "ProcessOrder",
      capability_query: { all_of: [:orders], governance: { trust: :trusted } },
      input_mapping: { id: :order_id },
      path: "remote/order_result"
    )
    deferred = Igniter::Runtime::DeferredResult.build(
      token: "route-order-42",
      payload: { query: { all_of: [:orders] } },
      source_node: :order_result,
      waiting_on: :order_result
    )
    explanation = {
      routing_mode: :capability,
      query: {
        all_of: [:orders],
        governance: { trust: :trusted }
      },
      selected_url: nil,
      eligible_count: 0,
      matched_count: 0,
      peer_count: 1,
      peers: [
        {
          name: "orders-blocked",
          matched: false,
          reasons: [:query_mismatch],
          match_details: { failed_dimensions: [:governance] }
        }
      ]
    }

    allow(Igniter::Cluster::Mesh.router).to receive(:find_peer_for_query)
      .and_raise(Igniter::Cluster::Mesh::DeferredCapabilityError.new(:orders, deferred, query: node.capability_query, explanation: explanation))

    expect {
      adapter.call(node: node, inputs: { id: 42 })
    }.to raise_error(Igniter::Cluster::Mesh::DeferredCapabilityError)

    report = Igniter::Cluster::Mesh.config.current_routing_report
    expect(report.dig(:routing, :plans)).to contain_exactly(
      include(action: :refresh_governance_checkpoint, automated: true),
      include(action: :relax_governance_requirements, automated: false)
    )
    expect(report.dig(:routing, :entries)).to contain_exactly(
      include(
        node_name: :order_result,
        status: :pending,
        token: "route-order-42",
        classification: include(incident: :governance_gate)
      )
    )
  end

  it "publishes failed routing reports into mesh config when pinned routing fails" do
    adapter = described_class.new
    node = Igniter::Model::RemoteNode.new(
      id: "test:3",
      name: :audit_result,
      contract_name: "WriteAudit",
      pinned_to: "audit-node",
      input_mapping: { event: :event },
      path: "remote/audit_result"
    )
    routing_trace = {
      routing_mode: :pinned,
      peer_name: "audit-node",
      known: true,
      selected_url: "http://audit:4567",
      reachable: false,
      reasons: [:unreachable]
    }

    allow(Igniter::Cluster::Mesh.router).to receive(:resolve_pinned)
      .with("audit-node")
      .and_raise(
        Igniter::Cluster::Mesh::IncidentError.new(
          "audit-node",
          nil,
          context: { routing_trace: routing_trace }
        )
      )

    expect {
      adapter.call(node: node, inputs: { event: "created" })
    }.to raise_error(Igniter::Cluster::Mesh::IncidentError)

    report = Igniter::Cluster::Mesh.config.current_routing_report
    expect(report.dig(:routing, :plans)).to contain_exactly(
      include(action: :refresh_peer_health, automated: true)
    )
    expect(report.dig(:routing, :entries)).to contain_exactly(
      include(
        node_name: :audit_result,
        status: :failed,
        classification: include(incident: :peer_unreachable)
      )
    )
  end
end
