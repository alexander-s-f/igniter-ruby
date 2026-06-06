# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::LeasePolicy do
  let(:owner) do
    Igniter::Cluster::Peer.new(
      name: :pricing_node,
      capabilities: %i[compose pricing],
      transport: ->(_request) { nil }
    )
  end

  let(:ownership_plan) do
    Igniter::Cluster::OwnershipPlan.new(
      mode: :assigned,
      claims: [
        Igniter::Cluster::OwnershipClaim.new(target: "order-42", owner: owner)
      ]
    )
  end

  it "turns ownership assignments into explicit renewable leases" do
    issued_at = Time.utc(2026, 4, 23, 12, 0, 0)
    policy = described_class.new(
      name: :ephemeral,
      ttl_seconds: 120,
      renewable: true,
      clock: -> { issued_at }
    )

    plan = policy.plan(target: "order-42", ownership_plan: ownership_plan)

    expect(plan.mode).to eq(:granted)
    expect(plan.owner_names).to eq([:pricing_node])
    expect(plan.grants.map(&:to_h)).to contain_exactly(
      include(
        target: "order-42",
        owner: :pricing_node,
        ttl_seconds: 120,
        renewable: true,
        issued_at: "2026-04-23T12:00:00Z",
        expires_at: "2026-04-23T12:02:00Z"
      )
    )
    expect(plan.explanation.to_h).to include(code: :lease_plan)
  end
end
