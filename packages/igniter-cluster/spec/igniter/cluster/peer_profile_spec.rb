# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::PeerProfile do
  it "normalizes cluster peer identity into a structured profile" do
    catalog = Igniter::Cluster::CapabilityCatalog.new(
      definitions: [
        Igniter::Cluster::CapabilityDefinition.new(
          name: :pricing,
          traits: [:financial],
          labels: { domain: "commerce" }
        )
      ]
    )
    profile = described_class.new(
      name: "pricing_node",
      capabilities: ["pricing", :compose, :pricing],
      roles: ["compute", :pricing],
      labels: { "tier" => "gold", zone: "eu-west-1a" },
      region: :eu_west,
      zone: :eu_west_1a,
      metadata: { owner: :mesh },
      capability_catalog: catalog
    )

    expect(profile.to_h).to include(
      name: :pricing_node,
      capabilities: %i[compose pricing],
      capability_definitions: [include(name: :pricing, traits: [:financial], labels: { domain: "commerce" })],
      capability_traits: [:financial],
      roles: %i[compute pricing],
      topology: {
        region: "eu_west",
        zone: "eu_west_1a",
        labels: { tier: "gold", zone: "eu-west-1a" },
        metadata: {}
      },
      labels: { tier: "gold", zone: "eu-west-1a" },
      region: "eu_west",
      zone: "eu_west_1a",
      metadata: { owner: :mesh }
    )
    expect(profile).to be_tagged(:tier, "gold")
    expect(profile).to be_tagged(:zone)
    expect(profile).to be_supports_capabilities([:pricing])
    expect(profile).to be_supports_traits([:financial])
    expect(profile).to be_matches_labels(tier: "gold")
    expect(profile).to be_matches_region("eu_west")
    expect(profile).to be_matches_zone("eu_west_1a")
  end
end
