# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::ClusterDiagnosticsReport do
  it "aggregates transport and mesh-facing diagnostics into one operator artifact" do
    report = described_class.new(
      kind: :mesh,
      status: :completed,
      query: { required_capabilities: [:pricing] },
      projection_report: { mode: :mesh_candidates, candidate_names: [:pricing_node] },
      mesh: { trace_id: "mesh/ownership/pricing_node/1", attempt_count: 1 },
      event_log: Igniter::Cluster::ClusterEventLog.new(
        events: [
          Igniter::Cluster::ClusterEvent.new(kind: :projection, status: :resolved),
          Igniter::Cluster::ClusterEvent.new(kind: :mesh, status: :completed)
        ]
      ),
      operator_timeline: Igniter::Cluster::OperatorTimeline.new(
        kind: :mesh,
        status: :completed,
        event_log: Igniter::Cluster::ClusterEventLog.new(
          events: [
            Igniter::Cluster::ClusterEvent.new(kind: :projection, status: :resolved),
            Igniter::Cluster::ClusterEvent.new(kind: :mesh, status: :completed)
          ]
        )
      ),
      metadata: { source: :spec }
    )

    expect(report.to_h).to include(
      kind: :mesh,
      status: :completed,
      query: include(required_capabilities: [:pricing]),
      projection_report: include(mode: :mesh_candidates, candidate_names: [:pricing_node]),
      mesh: include(trace_id: "mesh/ownership/pricing_node/1", attempt_count: 1),
      event_log: include(event_count: 2, events: include(include(kind: :projection), include(kind: :mesh))),
      operator_timeline: include(kind: :mesh, status: :completed, event_count: 2),
      metadata: include(source: :spec)
    )
  end
end
