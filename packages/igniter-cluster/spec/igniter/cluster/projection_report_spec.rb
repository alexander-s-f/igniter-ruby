# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::ProjectionReport do
  it "summarizes projection stages and selected peer view as an operational report" do
    query = Igniter::Cluster::CapabilityQuery.new(required_capabilities: [:pricing])
    peer = Igniter::Cluster::Peer.new(
      name: :pricing_node,
      capabilities: %i[compose pricing],
      transport: ->(_request) { nil }
    )
    peer_view = Igniter::Cluster::PeerView.new(
      peer: peer,
      query: query,
      included: true
    )
    projection = Igniter::Cluster::MembershipProjection.new(
      mode: :capability_filtered,
      query: query,
      peer_views: [peer_view],
      candidate_views: [peer_view],
      stages: [
        Igniter::Cluster::ProjectionStage.new(
          name: :capabilities,
          input_peer_names: [:pricing_node],
          output_peer_names: [:pricing_node]
        )
      ]
    )

    report = described_class.new(
      mode: :capability_filtered,
      status: :resolved,
      projection: projection,
      selected_peer_view: peer_view,
      metadata: { scope: :route }
    )

    expect(report.to_h).to include(
      mode: :capability_filtered,
      status: :resolved,
      candidate_names: [:pricing_node],
      stages: [include(name: :capabilities, output_peer_names: [:pricing_node])],
      selected_peer_view: include(peer: :pricing_node, included: true),
      metadata: include(scope: :route)
    )
  end
end
