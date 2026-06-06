# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::MembershipSnapshot do
  it "builds explicit references over feed identity and snapshot lineage" do
    feed = Igniter::Cluster::MembershipFeed.new(
      name: :registry,
      metadata: { adapter: :memory }
    )
    event = Igniter::Cluster::MeshMembershipEvent.new(
      version: 2,
      type: :peer_joined,
      peer_name: :pricing_node
    )

    snapshot = described_class.new(
      feed: feed,
      snapshot_id: "registry/2",
      previous_snapshot_id: "registry/1",
      version: 2,
      epoch: "registry/2",
      lineage: %w[registry/1 registry/2],
      peer_names: [:pricing_node],
      available_peer_names: [:pricing_node],
      events: [event],
      metadata: { source: :spec }
    )

    expect(snapshot.reference).to include(
      feed: include(name: :registry, metadata: include(adapter: :memory)),
      snapshot_id: "registry/2",
      previous_snapshot_id: "registry/1",
      version: 2,
      epoch: "registry/2",
      lineage: %w[registry/1 registry/2]
    )
    expect(snapshot.to_h).to include(
      peer_names: [:pricing_node],
      available_peer_names: [:pricing_node],
      events: [include(type: :peer_joined, peer: :pricing_node)],
      metadata: include(source: :spec)
    )
  end
end
