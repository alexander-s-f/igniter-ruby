# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::MembershipDelta do
  it "captures canonical change sets between snapshot references" do
    discovery_feed = Igniter::Cluster::DiscoveryFeed.new(
      name: :registry_discovery,
      metadata: { adapter: :memory }
    )
    membership_feed = Igniter::Cluster::MembershipFeed.new(
      name: :registry,
      discovery_feed: discovery_feed
    )
    event = Igniter::Cluster::MeshMembershipEvent.new(
      version: 2,
      type: :peer_joined,
      peer_name: :pricing_node
    )

    delta = described_class.new(
      feed: membership_feed,
      from_snapshot_ref: {
        feed: membership_feed.to_h,
        snapshot_id: "registry/1",
        version: 1,
        epoch: "registry/1",
        lineage: ["registry/1"]
      },
      to_snapshot_ref: {
        feed: membership_feed.to_h,
        snapshot_id: "registry/2",
        previous_snapshot_id: "registry/1",
        version: 2,
        epoch: "registry/2",
        lineage: %w[registry/1 registry/2]
      },
      joined_peer_names: [:pricing_node],
      events: [event],
      metadata: { source: :spec }
    )

    expect(delta.to_h).to include(
      feed: include(
        name: :registry,
        discovery_feed: include(name: :registry_discovery)
      ),
      from_snapshot_ref: include(snapshot_id: "registry/1"),
      to_snapshot_ref: include(snapshot_id: "registry/2"),
      joined_peer_names: [:pricing_node],
      left_peer_names: [],
      updated_peer_names: [],
      events: [include(type: :peer_joined, peer: :pricing_node)],
      metadata: include(source: :spec)
    )
  end
end
