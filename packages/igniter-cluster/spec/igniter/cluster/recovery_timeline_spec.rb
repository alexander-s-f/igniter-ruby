# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::RecoveryTimeline do
  it "represents incident recovery as a temporal event sequence" do
    event_log = Igniter::Cluster::ClusterEventLog.new(
      events: [
        Igniter::Cluster::ClusterEvent.new(kind: :incident_detected, status: :completed),
        Igniter::Cluster::ClusterEvent.new(kind: :failover_action, status: :completed),
        Igniter::Cluster::ClusterEvent.new(kind: :recovery_outcome, status: :recovered)
      ]
    )

    timeline = described_class.new(
      kind: :degraded_health,
      status: :completed,
      event_log: event_log,
      metadata: { source: :spec }
    )

    expect(timeline.to_h).to include(
      kind: :degraded_health,
      status: :completed,
      event_count: 3,
      event_log: include(
        event_count: 3,
        events: include(
          include(kind: :incident_detected, status: :completed),
          include(kind: :failover_action, status: :completed),
          include(kind: :recovery_outcome, status: :recovered)
        )
      ),
      metadata: include(source: :spec)
    )
  end
end
