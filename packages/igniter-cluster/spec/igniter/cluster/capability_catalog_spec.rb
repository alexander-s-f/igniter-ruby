# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::CapabilityCatalog do
  it "registers and resolves first-class capability definitions" do
    catalog = described_class.new
    catalog.register(
      Igniter::Cluster::CapabilityDefinition.new(
        name: :pricing,
        traits: %i[compute financial],
        description: "pricing operations",
        labels: { domain: "commerce" },
        metadata: { owner: :billing }
      )
    )

    expect(catalog).to be_capability(:pricing)
    expect(catalog.fetch(:pricing).to_h).to include(
      name: :pricing,
      traits: %i[compute financial],
      description: "pricing operations",
      labels: { domain: "commerce" },
      metadata: { owner: :billing }
    )
    expect(catalog.resolve(%i[pricing missing]).map(&:name)).to eq([:pricing])
    expect(catalog.with_traits([:financial]).map(&:name)).to eq([:pricing])
  end
end
