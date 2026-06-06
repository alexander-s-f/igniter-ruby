# frozen_string_literal: true

require "igniter/errors"
require "igniter/application"

require_relative "cluster/errors"
require_relative "cluster/capability_definition"
require_relative "cluster/capability_catalog"
require_relative "cluster/peer_topology"
require_relative "cluster/peer_health"
require_relative "cluster/peer_profile"
require_relative "cluster/peer"
require_relative "cluster/peer_view"
require_relative "cluster/projection_stage"
require_relative "cluster/projection_policy"
require_relative "cluster/projection_report"
require_relative "cluster/projection_executor"
require_relative "cluster/cluster_diagnostics_report"
require_relative "cluster/cluster_diagnostics_executor"
require_relative "cluster/memory_peer_registry"
require_relative "cluster/capability_query"
require_relative "cluster/decision_explanation"
require_relative "cluster/rebalance_move"
require_relative "cluster/rebalance_plan"
require_relative "cluster/ownership_claim"
require_relative "cluster/ownership_plan"
require_relative "cluster/lease_grant"
require_relative "cluster/lease_plan"
require_relative "cluster/failover_step"
require_relative "cluster/failover_plan"
require_relative "cluster/remediation_step"
require_relative "cluster/remediation_plan"
require_relative "cluster/plan_action_result"
require_relative "cluster/plan_execution_report"
require_relative "cluster/plan_executor"
require_relative "cluster/mesh_execution_request"
require_relative "cluster/mesh_execution_response"
require_relative "cluster/mesh_execution_attempt"
require_relative "cluster/mesh_execution_trace"
require_relative "cluster/discovery_feed"
require_relative "cluster/membership_feed"
require_relative "cluster/membership_delta"
require_relative "cluster/membership_projection"
require_relative "cluster/membership_snapshot"
require_relative "cluster/mesh_membership_event"
require_relative "cluster/mesh_membership"
require_relative "cluster/mesh_membership_source"
require_relative "cluster/registry_membership_source"
require_relative "cluster/peer_discovery"
require_relative "cluster/mesh_retry_policy"
require_relative "cluster/mesh_admission_result"
require_relative "cluster/mesh_trust_policy"
require_relative "cluster/mesh_admission"
require_relative "cluster/mesh_executor"
require_relative "cluster/route_policy"
require_relative "cluster/policy_router"
require_relative "cluster/admission_policy"
require_relative "cluster/policy_admission"
require_relative "cluster/placement_policy"
require_relative "cluster/policy_placement"
require_relative "cluster/topology_policy"
require_relative "cluster/ownership_policy"
require_relative "cluster/lease_policy"
require_relative "cluster/health_policy"
require_relative "cluster/remediation_policy"
require_relative "cluster/capability_router"
require_relative "cluster/permissive_admission"
require_relative "cluster/route_request"
require_relative "cluster/placement_decision"
require_relative "cluster/direct_placement"
require_relative "cluster/route"
require_relative "cluster/admission_result"
require_relative "cluster/cluster_event"
require_relative "cluster/cluster_event_log"
require_relative "cluster/operator_timeline"
require_relative "cluster/cluster_incident"
require_relative "cluster/incident_entry"
require_relative "cluster/incident_action"
require_relative "cluster/incident_workflow"
require_relative "cluster/active_incident_set"
require_relative "cluster/memory_incident_registry"
require_relative "cluster/recovery_timeline"
require_relative "cluster/incident_executor"
require_relative "cluster/transport_adapter"
require_relative "cluster/kernel_seams"
require_relative "cluster/kernel"
require_relative "cluster/profile"
require_relative "cluster/environment"

module Igniter
  module Cluster
    class << self
      def build_kernel(*packs)
        kernel = Kernel.new
        packs.flatten.compact.each { |pack| kernel.install_pack(pack) }
        kernel
      end

      def build_profile(*packs)
        build_kernel(*packs).finalize
      end

      def with(*packs)
        Environment.new(profile: build_profile(*packs))
      end
    end
  end
end
