# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::AdmissionPolicy do
  let(:peer) do
    Igniter::Cluster::Peer.new(
      name: :pricing_node,
      capabilities: %i[compose pricing],
      transport: ->(_request) { nil }
    )
  end

  let(:query) do
    Igniter::Cluster::CapabilityQuery.new(required_capabilities: [:pricing])
  end

  let(:route) do
    Igniter::Cluster::Route.new(peer: peer, mode: :capability)
  end

  let(:request) do
    Igniter::Cluster::RouteRequest.new(
      session_id: "mesh/pricing_total/1",
      kind: :compose,
      operation_name: :pricing_total,
      query: query,
      metadata: {},
      profile_fingerprint: "contracts:test"
    )
  end

  it "accepts through the permissive default policy" do
    result = described_class.permissive.admit(request: request, route: route)

    expect(result).to be_allowed
    expect(result.reason.to_h).to include(code: :permissive_accept)
  end

  it "can block peers declaratively" do
    policy = described_class.new(name: :restricted, blocked_peers: [:pricing_node])
    result = policy.admit(request: request, route: route)

    expect(result).not_to be_allowed
    expect(result.code).to eq(:blocked_peer)
    expect(result.reason.to_h).to include(code: :blocked_peer)
  end
end
