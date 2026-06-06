# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::OwnershipPolicy do
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

  let(:topology_policy) do
    Igniter::Cluster::TopologyPolicy.new(
      name: :locality,
      required_labels: { tier: "gold" },
      preferred_zone: :eu_west_1a
    )
  end

  let(:source_peer) do
    Igniter::Cluster::Peer.new(
      name: :fallback_node,
      capabilities: %i[compose pricing],
      labels: { tier: "silver" },
      region: :eu_west,
      zone: :eu_west_1b,
      capability_catalog: catalog,
      transport: ->(_request) { nil }
    )
  end

  let(:destination_peer) do
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

  it "assigns ownership to topology-compliant owners" do
    policy = described_class.distributed
    query = Igniter::Cluster::CapabilityQuery.new(
      required_capabilities: [:pricing],
      required_traits: [:financial],
      capability_catalog: catalog
    )

    plan = policy.plan(
      peers: [source_peer, destination_peer],
      query: query,
      target: "order-42",
      topology_policy: topology_policy
    )

    expect(plan.mode).to eq(:assigned)
    expect(plan.owner_names).to eq([:pricing_node])
    expect(plan.claims.map(&:to_h)).to contain_exactly(
      include(target: "order-42", owner: :pricing_node)
    )
    expect(plan.explanation.to_h).to include(code: :ownership_plan)
  end
end
