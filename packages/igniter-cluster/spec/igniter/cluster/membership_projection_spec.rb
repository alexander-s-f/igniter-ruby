# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::MembershipProjection do
  it "projects explainable peer views over query intent" do
    catalog = Igniter::Cluster::CapabilityCatalog.new(
      definitions: [
        Igniter::Cluster::CapabilityDefinition.new(
          name: :pricing,
          traits: [:financial]
        )
      ]
    )
    query = Igniter::Cluster::CapabilityQuery.new(
      required_capabilities: [:pricing],
      required_traits: [:financial],
      required_labels: { tier: "gold" },
      preferred_zone: :eu_west_1a,
      capability_catalog: catalog
    )
    pricing_peer = Igniter::Cluster::Peer.new(
      name: :pricing_node,
      capabilities: %i[compose pricing],
      labels: { tier: "gold" },
      zone: :eu_west_1a,
      capability_catalog: catalog,
      transport: ->(_request) { nil }
    )
    fallback_peer = Igniter::Cluster::Peer.new(
      name: :fallback_node,
      capabilities: [:compose],
      labels: { tier: "silver" },
      zone: :eu_west_1b,
      capability_catalog: catalog,
      transport: ->(_request) { nil }
    )

    pricing_view = Igniter::Cluster::PeerView.new(
      peer: pricing_peer,
      query: query,
      included: true,
      metadata: { source: :spec }
    )
    fallback_view = Igniter::Cluster::PeerView.new(
      peer: fallback_peer,
      query: query,
      included: false,
      metadata: { source: :spec }
    )

    projection = described_class.new(
      mode: :intent_filtered,
      query: query,
      peer_views: [pricing_view, fallback_view],
      candidate_views: [pricing_view],
      stages: [
        Igniter::Cluster::ProjectionStage.new(
          name: :capabilities,
          input_peer_names: %i[fallback_node pricing_node],
          output_peer_names: [:pricing_node]
        )
      ],
      metadata: { source: :spec }
    )

    expect(projection.candidates).to eq([pricing_peer])
    expect(projection.to_h).to include(
      mode: :intent_filtered,
      candidate_names: [:pricing_node],
      candidate_views: [include(peer: :pricing_node, included: true, capability_match: true, topology_match: true)],
      peer_views: include(
        include(peer: :pricing_node, included: true),
        include(peer: :fallback_node, included: false, capability_match: false, topology_match: false)
      ),
      stages: [include(name: :capabilities, output_peer_names: [:pricing_node])],
      metadata: include(source: :spec)
    )
  end
end
