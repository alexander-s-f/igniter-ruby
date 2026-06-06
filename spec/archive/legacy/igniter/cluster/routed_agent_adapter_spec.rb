# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe Igniter::Cluster::RoutedAgentAdapter do
  around do |example|
    previous_adapter = Igniter::Runtime.agent_adapter
    Igniter::Cluster::Mesh.reset!
    example.run
    Igniter::Cluster::Mesh.reset!
    Igniter::Runtime.agent_adapter = previous_adapter
  end

  it "installs itself as the runtime agent adapter when explicitly activated" do
    expect(Igniter::Runtime.agent_adapter).not_to be_a(described_class)

    Igniter::Cluster.activate_agent_adapter!

    expect(Igniter::Runtime.agent_adapter).to be_a(described_class)

    Igniter::Cluster.deactivate_agent_adapter!
    expect(Igniter::Runtime.agent_adapter).to be_a(Igniter::Runtime::RegistryAgentAdapter)
  end

  it "resolves capability-routed agents through mesh and delegates to transport" do
    transport = instance_double("AgentTransport")
    adapter = described_class.new(transport: transport)
    node = Igniter::Model::AgentNode.new(
      id: "test:1",
      name: :review,
      agent_name: :reviewer,
      message_name: :review,
      capability_query: { all_of: [:review], trust: { identity: :trusted } },
      input_mapping: { name: :customer_name }
    )

    allow(Igniter::Cluster::Mesh.router).to receive(:find_peer_for_query)
      .with(node.capability_query, kind_of(Igniter::Runtime::DeferredResult))
      .and_return("http://reviewers:4567")
    allow(transport).to receive(:call).and_return(
      status: :succeeded,
      output: "approved",
      agent_trace: { adapter: :remote_agent, outcome: :replied }
    )

    response = adapter.call(node: node, inputs: { name: "Alice" })

    expect(response).to include(status: :succeeded, output: "approved")
    expect(response[:agent_trace]).to include(
      adapter: :remote_agent,
      routing_mode: :static,
      route_url: "http://reviewers:4567",
      capability_query: { all_of: [:review], trust: { identity: :trusted } },
      remote: true
    )
  end

  it "maps deferred capability routing to a pending agent response" do
    transport = instance_double("AgentTransport")
    adapter = described_class.new(transport: transport)
    node = Igniter::Model::AgentNode.new(
      id: "test:2",
      name: :review,
      agent_name: :reviewer,
      message_name: :review,
      capability: :review,
      input_mapping: { name: :customer_name }
    )
    deferred = Igniter::Runtime::DeferredResult.build(
      token: "review-route-1",
      payload: { query: { all_of: [:review] } },
      source_node: :review,
      waiting_on: :review
    )
    explanation = {
      routing_mode: :capability,
      query: { all_of: [:review] },
      selected_url: nil
    }

    allow(transport).to receive(:call)
    allow(Igniter::Cluster::Mesh.router).to receive(:find_peer_for)
      .with(:review, kind_of(Igniter::Runtime::DeferredResult))
      .and_raise(Igniter::Cluster::Mesh::DeferredCapabilityError.new(:review, deferred, query: { all_of: [:review] }, explanation: explanation))

    response = adapter.call(node: node, inputs: { name: "Alice" })

    expect(response).to include(
      status: :pending,
      message: /No alive peer matching capability/,
      payload: include(routing_trace: explanation)
    )
    expect(response[:deferred_result]).to have_attributes(token: "review-route-1")
    expect(response[:agent_trace]).to include(
      adapter: :cluster_routed,
      routing_mode: :capability,
      outcome: :pending,
      reason: :routing_deferred
    )
    expect(transport).not_to have_received(:call)
  end

  it "maps pinned routing incidents to a failed agent response" do
    transport = instance_double("AgentTransport")
    adapter = described_class.new(transport: transport)
    node = Igniter::Model::AgentNode.new(
      id: "test:3",
      name: :review,
      agent_name: :reviewer,
      message_name: :review,
      pinned_to: "audit-node",
      input_mapping: { name: :customer_name }
    )

    allow(transport).to receive(:call)
    allow(Igniter::Cluster::Mesh.router).to receive(:resolve_pinned)
      .with("audit-node")
      .and_raise(Igniter::Cluster::Mesh::IncidentError.new("audit-node"))

    response = adapter.call(node: node, inputs: { name: "Alice" })

    expect(response).to include(
      status: :failed,
      error: include(message: /audit-node/)
    )
    expect(response[:agent_trace]).to include(
      adapter: :cluster_routed,
      routing_mode: :pinned,
      pinned_to: "audit-node",
      reason: :routing_incident
    )
    expect(transport).not_to have_received(:call)
  end
end
