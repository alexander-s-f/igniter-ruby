# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::MemoryIncidentRegistry do
  def build_report(status:, resolution:)
    incident = Igniter::Cluster::ClusterIncident.new(
      kind: :degraded_health,
      status: status,
      severity: :high,
      targets: ["order-42"],
      source_names: [:fallback_node],
      destination_names: [:pricing_node]
    )

    recovery_timeline = Igniter::Cluster::RecoveryTimeline.new(
      kind: :degraded_health,
      status: status,
      event_log: Igniter::Cluster::ClusterEventLog.new(
        events: [
          Igniter::Cluster::ClusterEvent.new(kind: :incident_detected, status: status),
          Igniter::Cluster::ClusterEvent.new(kind: :recovery_outcome, status: resolution)
        ]
      )
    )

    Igniter::Cluster::PlanExecutionReport.new(
      plan_kind: :failover,
      status: status,
      plan: Igniter::Cluster::FailoverPlan.new(
        mode: :failover,
        steps: [],
        metadata: {}
      ),
      action_results: [],
      incident: incident,
      recovery_timeline: recovery_timeline
    )
  end

  it "keeps durable incident history while exposing only latest unresolved incidents as active" do
    registry = described_class.new

    registry.record(build_report(status: :failed, resolution: :unresolved))
    registry.record(build_report(status: :completed, resolution: :recovered))

    expect(registry.entries.map(&:to_h)).to contain_exactly(
      include(
        id: "degraded_health/1",
        sequence: 1,
        active: true,
        resolution: :unresolved,
        incident: include(kind: :degraded_health, targets: ["order-42"])
      ),
      include(
        id: "degraded_health/2",
        sequence: 2,
        active: false,
        resolution: :recovered,
        incident: include(kind: :degraded_health, targets: ["order-42"])
      )
    )
    expect(registry.active_set).to be_empty
    expect(registry.active_set.to_h).to include(
      count: 0,
      incident_keys: []
    )
  end

  it "records operator workflow actions and lets terminal actions clear active incidents" do
    registry = described_class.new
    entry = registry.record(build_report(status: :failed, resolution: :unresolved))

    registry.record_action(entry.id, kind: :acknowledged, actor: :operator, note: "looking")
    registry.record_action(entry.incident_key, kind: :assigned, actor: :operator, metadata: { assignee: :sre })

    workflow = registry.workflow(entry)

    expect(workflow.to_h).to include(
      incident_key: entry.incident_key,
      state: :assigned,
      active: true,
      entry_count: 1,
      action_count: 2,
      action_kinds: %i[acknowledged assigned]
    )
    expect(registry.active_set.count).to eq(1)

    registry.record_action(entry.id, kind: :resolved, actor: :operator, note: "recovered")

    expect(registry.workflow(entry).to_h).to include(
      state: :resolved,
      active: false,
      action_kinds: %i[acknowledged assigned resolved]
    )
    expect(registry.active_set).to be_empty
  end
end
