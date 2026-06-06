# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::PlacementPolicy do
  let(:pricing_peer) do
    catalog = Igniter::Cluster::CapabilityCatalog.new(
      definitions: [
        Igniter::Cluster::CapabilityDefinition.new(
          name: :pricing,
          traits: [:financial]
        )
      ]
    )
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

  let(:fallback_peer) do
    Igniter::Cluster::Peer.new(
      name: :fallback_node,
      capabilities: [:compose],
      transport: ->(_request) { nil }
    )
  end

  it "honors preferred peer by default" do
    policy = described_class.direct
    query = Igniter::Cluster::CapabilityQuery.new(preferred_peer: :pricing_node)

    expect(policy.select_candidates(query: query, peers: [fallback_peer, pricing_peer])).to eq([pricing_peer])
    expect(policy.mode_for(query)).to eq(:pinned)
  end

  it "can filter candidates by requested capabilities" do
    policy = described_class.new(name: :targeted, filter_capabilities: true, candidate_limit: 1)
    query = Igniter::Cluster::CapabilityQuery.new(required_capabilities: [:pricing])

    expect(policy.select_candidates(query: query, peers: [fallback_peer, pricing_peer])).to eq([pricing_peer])
    expect(policy.mode_for(query)).to eq(:capability_filtered)
  end

  it "filters candidates by intent constraints even without preferred peer" do
    policy = described_class.new(name: :targeted, filter_capabilities: true)
    query = Igniter::Cluster::CapabilityQuery.new(
      required_traits: [:financial],
      required_labels: { tier: "gold" },
      preferred_zone: :eu_west_1a
    )

    expect(policy.select_candidates(query: query, peers: [fallback_peer, pricing_peer])).to eq([pricing_peer])
    expect(policy.mode_for(query)).to eq(:intent_filtered)
  end
end
