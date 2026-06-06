# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::CapabilityQuery do
  it "normalizes capabilities, peer, and metadata" do
    catalog = Igniter::Cluster::CapabilityCatalog.new(
      definitions: [
        Igniter::Cluster::CapabilityDefinition.new(
          name: :pricing,
          traits: [:financial]
        )
      ]
    )
    query = described_class.new(
      required_capabilities: ["pricing", :compose, :pricing],
      required_traits: ["financial", :financial],
      required_labels: { tier: "gold" },
      preferred_peer: "node_a",
      preferred_region: :eu_west,
      preferred_zone: :eu_west_1a,
      metadata: { region: "eu-west" },
      capability_catalog: catalog
    )

    expect(query.required_capabilities).to eq(%i[compose pricing])
    expect(query.required_traits).to eq([:financial])
    expect(query.required_labels).to eq(tier: "gold")
    expect(query.capability_definitions.map(&:name)).to eq([:pricing])
    expect(query.preferred_peer).to eq(:node_a)
    expect(query.preferred_region).to eq("eu_west")
    expect(query.preferred_zone).to eq("eu_west_1a")
    expect(query).to be_pinned
    expect(query.routing_mode).to eq(:pinned)
    expect(query.to_h).to include(
      required_capabilities: %i[compose pricing],
      required_capability_definitions: [include(name: :pricing, traits: [:financial])],
      required_traits: [:financial],
      required_trait_definitions: [include(name: :pricing, traits: [:financial])],
      required_labels: { tier: "gold" },
      preferred_peer: :node_a,
      preferred_region: "eu_west",
      preferred_zone: "eu_west_1a",
      metadata: { region: "eu-west" }
    )
  end

  it "supports the legacy routing metadata shape" do
    query = described_class.from_routing(
      all_of: [:pricing],
      peer: :node_a,
      region: :eu_west,
      zone: :eu_west_1a,
      metadata: { source: :legacy }
    )

    expect(query.required_capabilities).to eq([:pricing])
    expect(query.preferred_peer).to eq(:node_a)
    expect(query.preferred_region).to eq("eu_west")
    expect(query.preferred_zone).to eq("eu_west_1a")
    expect(query.metadata).to eq(source: :legacy)
  end
end
