# frozen_string_literal: true

module Igniter
  module Cluster
    class Environment
      attr_reader :profile

      def initialize(profile:)
        @profile = profile
      end

      def application
        @application ||= Igniter::Application::Environment.new(profile: profile.application_profile)
      end

      def plan_executor
        @plan_executor ||= PlanExecutor.new(environment: self)
      end

      def mesh_executor(metadata: {}, id_generator: nil, discovery: nil, retry_policy: nil,
                        trust_policy: nil, admission: nil, membership_source: nil)
        MeshExecutor.new(
          environment: self,
          metadata: metadata,
          id_generator: id_generator,
          discovery: discovery,
          retry_policy: retry_policy,
          trust_policy: trust_policy,
          admission: admission,
          membership_source: membership_source
        )
      end

      def compile(&block)
        application.compile(&block)
      end

      def execute(...)
        application.execute(...)
      end

      def run(...)
        application.run(...)
      end

      def diagnose(result)
        application.diagnose(result)
      end

      def register_peer(name, capabilities:, transport:, metadata: {}, roles: [], labels: {}, region: nil, zone: nil,
                        health: nil, health_status: :healthy, health_checks: {})
        peer_registry.register(
          Peer.new(
            name: name,
            capabilities: capabilities,
            transport: transport,
            metadata: metadata,
            roles: roles,
            labels: labels,
            region: region,
            zone: zone,
            capability_catalog: profile.capability_catalog,
            health: health,
            health_status: health_status,
            health_checks: health_checks
          )
        )
      end

      def fetch_peer(name)
        peer_registry.fetch(name)
      end

      def peers
        peer_registry.peers
      end

      def incident_registry
        profile.incident_registry_seam
      end

      def fetch_incident(id)
        incident_registry.fetch(id)
      end

      def incidents
        incident_registry.entries
      end

      def active_incidents
        incident_registry.active_set
      end

      def incident_workflow(incident)
        incident_registry.workflow(incident)
      end

      def incident_workflows
        incident_registry.workflows
      end

      def acknowledge_incident(incident, actor: nil, note: nil, metadata: {})
        record_incident_action(incident, :acknowledged, actor: actor, note: note, metadata: metadata)
      end

      def assign_incident(incident, assignee:, actor: nil, note: nil, metadata: {})
        record_incident_action(
          incident,
          :assigned,
          actor: actor,
          note: note,
          metadata: metadata.merge(assignee: assignee.to_sym)
        )
      end

      def silence_incident(incident, actor: nil, note: nil, metadata: {})
        record_incident_action(incident, :silenced, actor: actor, note: note, metadata: metadata)
      end

      def escalate_incident(incident, actor: nil, note: nil, metadata: {})
        record_incident_action(incident, :escalated, actor: actor, note: note, metadata: metadata)
      end

      def resolve_incident(incident, actor: nil, note: nil, metadata: {})
        record_incident_action(incident, :resolved, actor: actor, note: note, metadata: metadata)
      end

      def close_incident(incident, actor: nil, note: nil, metadata: {})
        record_incident_action(incident, :closed, actor: actor, note: note, metadata: metadata)
      end

      def plan_rebalance(capabilities: [], traits: [], labels: {}, peer: nil, region: nil, zone: nil, query: nil,
                         policy: nil, metadata: {})
        effective_query = build_capability_query(
          query: query,
          capabilities: capabilities,
          traits: traits,
          labels: labels,
          peer: peer,
          region: region,
          zone: zone
        )
        effective_policy = policy || profile.topology_policy
        effective_policy.plan(peers: peers, query: effective_query, metadata: metadata)
      end

      def execute_plan(plan, handler: nil, metadata: {}, &block)
        plan_executor.execute(plan, handler: resolve_execution_handler(handler, block), metadata: metadata)
      end

      def execute_rebalance_plan(plan, handler: nil, metadata: {}, &block)
        plan_executor.execute_rebalance(plan, handler: resolve_execution_handler(handler, block), metadata: metadata)
      end

      def plan_ownership(target:, capabilities: [], traits: [], labels: {}, peer: nil, region: nil, zone: nil,
                         query: nil, policy: nil, metadata: {})
        effective_query = build_capability_query(
          query: query,
          capabilities: capabilities,
          traits: traits,
          labels: labels,
          peer: peer,
          region: region,
          zone: zone
        )
        effective_policy = policy || profile.ownership_policy
        effective_policy.plan(
          peers: peers,
          query: effective_query,
          target: target,
          topology_policy: profile.topology_policy,
          metadata: metadata
        )
      end

      def execute_ownership_plan(plan, handler: nil, metadata: {}, &block)
        plan_executor.execute_ownership(plan, handler: resolve_execution_handler(handler, block), metadata: metadata)
      end

      def plan_lease(target:, capabilities: [], traits: [], labels: {}, peer: nil, region: nil, zone: nil,
                     query: nil, ownership_plan: nil, ownership_policy: nil, policy: nil, metadata: {})
        effective_ownership_plan = ownership_plan || plan_ownership(
          target: target,
          capabilities: capabilities,
          traits: traits,
          labels: labels,
          peer: peer,
          region: region,
          zone: zone,
          query: query,
          policy: ownership_policy
        )
        effective_policy = policy || profile.lease_policy
        effective_policy.plan(
          target: target,
          ownership_plan: effective_ownership_plan,
          metadata: metadata
        )
      end

      def execute_lease_plan(plan, handler: nil, metadata: {}, &block)
        plan_executor.execute_lease(plan, handler: resolve_execution_handler(handler, block), metadata: metadata)
      end

      def plan_failover(target:, capabilities: [], traits: [], labels: {}, peer: nil, region: nil, zone: nil,
                        query: nil, ownership_policy: nil, topology_policy: nil, policy: nil, metadata: {})
        effective_query = build_capability_query(
          query: query,
          capabilities: capabilities,
          traits: traits,
          labels: labels,
          peer: peer,
          region: region,
          zone: zone
        )
        effective_policy = policy || profile.health_policy
        effective_policy.plan(
          peers: peers,
          query: effective_query,
          target: target,
          ownership_policy: ownership_policy || profile.ownership_policy,
          topology_policy: topology_policy || profile.topology_policy,
          metadata: metadata
        )
      end

      def execute_failover_plan(plan, handler: nil, metadata: {}, &block)
        plan_executor.execute_failover(plan, handler: resolve_execution_handler(handler, block), metadata: metadata)
      end

      def plan_remediation(active_incidents: nil, policy: nil, metadata: {})
        effective_policy = policy || profile.remediation_policy
        effective_policy.plan(
          active_incidents: active_incidents || self.active_incidents,
          metadata: metadata
        )
      end

      def execute_remediation_plan(plan, handler: nil, metadata: {}, &block)
        plan_executor.execute_remediation(plan, handler: resolve_execution_handler(handler, block), metadata: metadata)
      end

      def execute_plan_via_mesh(plan, executor: nil, metadata: {})
        resolved_executor = executor || mesh_executor(metadata: metadata)
        execute_plan(
          plan,
          handler: lambda do |plan_kind:, action:, environment:|
            resolved_executor.call(plan: plan, plan_kind: plan_kind, action: action, environment: environment)
          end,
          metadata: metadata.merge(mesh: true)
        )
      end

      def compose_invoker(capabilities: [], traits: [], labels: {}, peer: nil, region: nil, zone: nil, query: nil,
                          namespace: :cluster_compose, metadata: {}, id_generator: nil)
        build_remote_invoker(
          factory: :remote_compose_invoker,
          query: build_capability_query(
            query: query,
            capabilities: capabilities,
            traits: traits,
            labels: labels,
            peer: peer,
            region: region,
            zone: zone
          ),
          namespace: namespace,
          metadata: metadata,
          id_generator: id_generator
        )
      end

      def collection_invoker(
        capabilities: [],
        traits: [],
        labels: {},
        peer: nil,
        region: nil,
        zone: nil,
        query: nil,
        namespace: :cluster_collection,
        metadata: {},
        id_generator: nil
      )
        build_remote_invoker(
          factory: :remote_collection_invoker,
          query: build_capability_query(
            query: query,
            capabilities: capabilities,
            traits: traits,
            labels: labels,
            peer: peer,
            region: region,
            zone: zone
          ),
          namespace: namespace,
          metadata: metadata,
          id_generator: id_generator
        )
      end

      def dispatch(request)
        route_request = RouteRequest.from_transport_request(request, capability_catalog: profile.capability_catalog)
        placement = placement_seam.place(request: route_request, peers: peers)
        route = router_seam.route(request: route_request, placement: placement)
        admission = admission_seam.admit(request: route_request, route: route)
        raise AdmissionError, "admission denied for #{request.session_id}: #{admission.code}" unless admission.allowed?

        transport_seam.call(route: route, request: request, placement: placement, admission: admission)
      end

      def remote_transport
        @remote_transport ||= lambda do |request:|
          dispatch(request)
        end
      end

      private

      def resolve_execution_handler(handler, block)
        handler || block
      end

      def record_incident_action(incident, kind, actor:, note:, metadata:)
        incident_registry.record_action(
          incident,
          kind: kind,
          actor: actor,
          note: note,
          metadata: metadata
        )
      end

      def build_remote_invoker(factory:, query:, namespace:, metadata:, id_generator:)
        application.public_send(
          factory,
          transport: remote_transport,
          namespace: namespace,
          metadata: metadata.merge(routing: query.to_h),
          id_generator: id_generator
        )
      end

      def build_capability_query(query: nil, capabilities: [], traits: [], labels: {}, peer: nil, region: nil,
                                 zone: nil)
        return query if query.is_a?(CapabilityQuery)

        CapabilityQuery.new(
          required_capabilities: capabilities,
          required_traits: traits,
          required_labels: labels,
          preferred_peer: peer,
          preferred_region: region,
          preferred_zone: zone,
          capability_catalog: profile.capability_catalog
        )
      end

      def transport_seam
        profile.transport_seam
      end

      def router_seam
        profile.router_seam
      end

      def admission_seam
        profile.admission_seam
      end

      def placement_seam
        profile.placement_seam
      end

      def peer_registry
        profile.peer_registry_seam
      end
    end
  end
end
