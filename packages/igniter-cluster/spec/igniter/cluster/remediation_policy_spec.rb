# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::RemediationPolicy do
  def build_active_incidents
    incident = Igniter::Cluster::ClusterIncident.new(
      kind: :degraded_health,
      status: :failed,
      severity: :critical,
      targets: ["order-42"],
      source_names: [:fallback_node],
      destination_names: [:pricing_node]
    )

    entry = Igniter::Cluster::IncidentEntry.new(
      id: "degraded_health/1",
      sequence: 1,
      incident_key: "degraded_health|order-42|fallback_node|pricing_node|",
      plan_kind: :failover,
      status: :failed,
      resolution: :unresolved,
      incident: incident,
      recovery_timeline: Igniter::Cluster::RecoveryTimeline.new(
        kind: :degraded_health,
        status: :failed,
        event_log: Igniter::Cluster::ClusterEventLog.new(
          events: [
            Igniter::Cluster::ClusterEvent.new(kind: :incident_detected, status: :failed),
            Igniter::Cluster::ClusterEvent.new(kind: :recovery_outcome, status: :unresolved)
          ]
        )
      )
    )

    Igniter::Cluster::ActiveIncidentSet.new(entries: [entry])
  end

  it "translates active incidents into explicit remediation steps" do
    plan = described_class.default.plan(active_incidents: build_active_incidents, metadata: { source: :spec })

    expect(plan.to_h).to include(
      mode: :planned,
      targets: ["order-42"],
      incident_ids: ["degraded_health/1"],
      action_kinds: [:retry_failover],
      metadata: include(
        source: :spec,
        active_incident_count: 1,
        planned_action_kinds: [:retry_failover]
      ),
      explanation: include(code: :remediation_plan)
    )
    expect(plan.steps.map(&:to_h)).to contain_exactly(
      include(
        incident_id: "degraded_health/1",
        incident_kind: :degraded_health,
        target: "order-42",
        action: :retry_failover,
        source_name: :fallback_node,
        destination_name: :pricing_node,
        metadata: include(policy: :default, severity: :critical, resolution: :unresolved)
      )
    )
  end
end
