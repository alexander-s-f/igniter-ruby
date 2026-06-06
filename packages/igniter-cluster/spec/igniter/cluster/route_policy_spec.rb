# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::RoutePolicy do
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
      capabilities: %i[compose pricing],
      transport: ->(_request) { nil }
    )
  end

  it "selects a preferred peer by default" do
    policy = described_class.capability
    query = Igniter::Cluster::CapabilityQuery.new(
      required_capabilities: [:pricing],
      preferred_peer: :pricing_node
    )

    expect(policy.select_peer(query: query, candidates: [fallback_peer, pricing_peer])).to eq(pricing_peer)
    expect(policy.route_mode_for(query)).to eq(:pinned)
  end

  it "can ignore preferred peers declaratively" do
    policy = described_class.new(name: :capability_only, honor_preferred_peer: false)
    query = Igniter::Cluster::CapabilityQuery.new(
      required_capabilities: [:pricing],
      preferred_peer: :pricing_node
    )

    expect(policy.select_peer(query: query, candidates: [fallback_peer, pricing_peer])).to eq(fallback_peer)
    expect(policy.route_mode_for(query)).to eq(:capability)
  end

  it "matches richer intent over traits and topology filters" do
    policy = described_class.capability
    query = Igniter::Cluster::CapabilityQuery.new(
      required_traits: [:financial],
      required_labels: { tier: "gold" },
      preferred_region: :eu_west,
      preferred_zone: :eu_west_1a
    )

    expect(policy.select_peer(query: query, candidates: [fallback_peer, pricing_peer])).to eq(pricing_peer)
    expect(policy.explanation_for(query: query, peer: pricing_peer).to_h).to include(code: :intent_route)
  end
end
