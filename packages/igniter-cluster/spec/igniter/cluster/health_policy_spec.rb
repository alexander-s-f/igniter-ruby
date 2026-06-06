# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::HealthPolicy do
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

  let(:ownership_policy) do
    Igniter::Cluster::OwnershipPolicy.distributed
  end

  let(:topology_policy) do
    Igniter::Cluster::TopologyPolicy.new(
      name: :locality,
      required_labels: { tier: "gold" },
      preferred_zone: :eu_west_1a
    )
  end

  let(:query) do
    Igniter::Cluster::CapabilityQuery.new(
      required_capabilities: [:pricing],
      required_traits: [:financial],
      capability_catalog: catalog
    )
  end

  let(:degraded_peer) do
    Igniter::Cluster::Peer.new(
      name: :fallback_node,
      capabilities: %i[compose pricing],
      labels: { tier: "silver" },
      region: :eu_west,
      zone: :eu_west_1b,
      capability_catalog: catalog,
      health_status: :degraded,
      transport: ->(_request) { nil }
    )
  end

  let(:healthy_peer) do
    Igniter::Cluster::Peer.new(
      name: :pricing_node,
      capabilities: %i[compose pricing],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      capability_catalog: catalog,
      health_status: :healthy,
      transport: ->(_request) { nil }
    )
  end

  it "builds explicit failover plans away from degraded peers" do
    plan = described_class.availability_aware.plan(
      peers: [degraded_peer, healthy_peer],
      query: query,
      target: "order-42",
      ownership_policy: ownership_policy,
      topology_policy: topology_policy
    )

    expect(plan.mode).to eq(:failover)
    expect(plan.source_names).to eq([:fallback_node])
    expect(plan.destination_names).to eq([:pricing_node])
    expect(plan.steps.map(&:to_h)).to contain_exactly(
      include(target: "order-42", source: :fallback_node, destination: :pricing_node)
    )
    expect(plan.explanation.to_h).to include(code: :failover_plan)
  end
end
