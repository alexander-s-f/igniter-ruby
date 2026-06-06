# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::OperatorTimeline do
  it "summarizes a cluster event log into an operator-facing timeline" do
    event_log = Igniter::Cluster::ClusterEventLog.new(
      events: [
        Igniter::Cluster::ClusterEvent.new(kind: :placement, status: :resolved),
        Igniter::Cluster::ClusterEvent.new(kind: :route, status: :resolved),
        Igniter::Cluster::ClusterEvent.new(kind: :admission, status: :allowed)
      ],
      metadata: { source: :spec }
    )

    timeline = described_class.new(
      kind: :transport,
      status: :completed,
      event_log: event_log,
      metadata: { source: :spec }
    )

    expect(timeline.to_h).to include(
      kind: :transport,
      status: :completed,
      event_count: 3,
      event_log: include(
        event_count: 3,
        events: include(
          include(kind: :placement, status: :resolved),
          include(kind: :route, status: :resolved),
          include(kind: :admission, status: :allowed)
        )
      ),
      metadata: include(source: :spec)
    )
  end
end
