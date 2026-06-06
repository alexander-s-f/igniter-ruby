# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::PeerHealth do
  it "models peer availability and observability as a first-class value" do
    observed_at = Time.utc(2026, 4, 23, 12, 0, 0)
    health = described_class.new(
      status: :degraded,
      checks: { latency: :warn, transport: :ok },
      observed_at: observed_at,
      metadata: { source: :spec }
    )

    expect(health).to be_degraded
    expect(health).not_to be_available
    expect(health).to be_available(allow_degraded: true)
    expect(health.to_h).to eq(
      status: :degraded,
      checks: { latency: :warn, transport: :ok },
      observed_at: "2026-04-23T12:00:00Z",
      metadata: { source: :spec }
    )
  end
end
