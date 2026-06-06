# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::PeerTopology do
  it "normalizes and matches topology attributes" do
    topology = described_class.new(
      region: :eu_west,
      zone: :eu_west_1a,
      labels: { "tier" => "gold", shard: "a" },
      metadata: { source: :spec }
    )

    expect(topology.to_h).to eq(
      region: "eu_west",
      zone: "eu_west_1a",
      labels: { tier: "gold", shard: "a" },
      metadata: { source: :spec }
    )
    expect(topology).to be_tagged(:tier, "gold")
    expect(topology).to be_matches_labels(tier: "gold")
    expect(topology).to be_matches_region("eu_west")
    expect(topology).to be_matches_zone("eu_west_1a")
  end
end
