# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::ProjectionPolicy do
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

  let(:pricing_peer) do
    Igniter::Cluster::Peer.new(
      name: :pricing_node,
      capabilities: %i[compose pricing],
      labels: { tier: "gold" },
      zone: :eu_west_1a,
      capability_catalog: catalog,
      transport: ->(_request) { nil }
    )
  end

  let(:fallback_peer) do
    Igniter::Cluster::Peer.new(
      name: :fallback_node,
      capabilities: [:compose],
      labels: { tier: "silver" },
      zone: :eu_west_1b,
      capability_catalog: catalog,
      transport: ->(_request) { nil }
    )
  end

  it "builds explicit placement stages over preferred peer, topology, capabilities, and limit" do
    policy = described_class.new(name: :placement_targeted)
    placement_policy = Igniter::Cluster::PlacementPolicy.new(
      name: :targeted,
      filter_capabilities: true,
      candidate_limit: 1
    )
    query = Igniter::Cluster::CapabilityQuery.new(
      required_capabilities: [:pricing],
      required_traits: [:financial],
      required_labels: { tier: "gold" },
      preferred_zone: :eu_west_1a,
      capability_catalog: catalog
    )

    stages = policy.project_placement(
      query: query,
      peers: [fallback_peer, pricing_peer],
      placement_policy: placement_policy
    )

    expect(stages.map(&:to_h)).to include(
      include(name: :source, output_peer_names: %i[fallback_node pricing_node]),
      include(name: :preferred_peer, output_peer_names: %i[fallback_node pricing_node]),
      include(name: :topology, output_peer_names: [:pricing_node]),
      include(name: :capabilities, output_peer_names: [:pricing_node]),
      include(name: :candidate_limit, output_peer_names: [:pricing_node])
    )
  end
end
