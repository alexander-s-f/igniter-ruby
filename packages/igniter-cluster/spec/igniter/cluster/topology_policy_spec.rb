# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::TopologyPolicy do
  let(:catalog) do
    Igniter::Cluster::CapabilityCatalog.new(
      definitions: [
        Igniter::Cluster::CapabilityDefinition.new(
          name: :pricing,
          traits: [:financial]
        )
      ]
    )
  end

  let(:source_peer) do
    Igniter::Cluster::Peer.new(
      name: :fallback_node,
      capabilities: %i[compose pricing],
      labels: { tier: "silver" },
      region: :eu_west,
      zone: :eu_west_1b,
      capability_catalog: catalog,
      transport: ->(_request) { nil }
    )
  end

  let(:destination_peer) do
    Igniter::Cluster::Peer.new(
      name: :pricing_node,
      capabilities: %i[compose pricing],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      capability_catalog: catalog,
      transport: ->(_request) { nil }
    )
  end

  it "builds an explicit rebalance plan toward topology-compliant peers" do
    policy = described_class.new(name: :locality, required_labels: { tier: "gold" }, preferred_zone: :eu_west_1a)
    query = Igniter::Cluster::CapabilityQuery.new(
      required_capabilities: [:pricing],
      required_traits: [:financial],
      capability_catalog: catalog
    )

    plan = policy.plan(peers: [source_peer, destination_peer], query: query)

    expect(plan.mode).to eq(:rebalance)
    expect(plan.destination_names).to eq([:pricing_node])
    expect(plan.source_names).to eq([:fallback_node])
    expect(plan.moves.map(&:to_h)).to contain_exactly(
      include(source: :fallback_node, destination: :pricing_node)
    )
    expect(plan.explanation.to_h).to include(code: :topology_rebalance)
  end
end
