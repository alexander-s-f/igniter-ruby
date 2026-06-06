# frozen_string_literal: true

module Igniter
  module Cluster
    module KernelSeams
      def capability(name = nil, definition: nil, **attributes)
        return capability_catalog.fetch(name) if definition_query?(name, definition, attributes)

        capability_catalog.register(
          definition || CapabilityDefinition.new(name: name, **attributes)
        )
        self
      end

      def capability_catalog(catalog = nil)
        return @capability_catalog if catalog.nil?

        @capability_catalog = catalog
        self
      end

      def route_policy(name = nil, policy: nil, **attributes)
        return @route_policy if policy_query?(name, policy, attributes)

        @route_policy = policy || RoutePolicy.new(name: name || :route_policy, **attributes)
        configure_default_seam(:router, @route_policy.name, PolicyRouter.new(policy: @route_policy))
        self
      end

      def admission_policy(name = nil, policy: nil, **attributes)
        return @admission_policy if policy_query?(name, policy, attributes)

        @admission_policy = policy || AdmissionPolicy.new(name: name || :admission_policy, **attributes)
        configure_default_seam(:admission, @admission_policy.name, PolicyAdmission.new(policy: @admission_policy))
        self
      end

      def placement_policy(name = nil, policy: nil, **attributes)
        return @placement_policy if policy_query?(name, policy, attributes)

        @placement_policy = policy || PlacementPolicy.new(name: name || :placement_policy, **attributes)
        configure_default_seam(:placement, @placement_policy.name, PolicyPlacement.new(policy: @placement_policy))
        self
      end

      def topology_policy(name = nil, policy: nil, **attributes)
        return @topology_policy if policy_query?(name, policy, attributes)

        @topology_policy = policy || TopologyPolicy.new(name: name || :topology_policy, **attributes)
        self
      end

      def ownership_policy(name = nil, policy: nil, **attributes)
        return @ownership_policy if policy_query?(name, policy, attributes)

        @ownership_policy = policy || OwnershipPolicy.new(name: name || :ownership_policy, **attributes)
        self
      end

      def lease_policy(name = nil, policy: nil, **attributes)
        return @lease_policy if policy_query?(name, policy, attributes)

        @lease_policy = policy || LeasePolicy.new(name: name || :lease_policy, **attributes)
        self
      end

      def health_policy(name = nil, policy: nil, **attributes)
        return @health_policy if policy_query?(name, policy, attributes)

        @health_policy = policy || HealthPolicy.new(name: name || :health_policy, **attributes)
        self
      end

      def remediation_policy(name = nil, policy: nil, **attributes)
        return @remediation_policy if policy_query?(name, policy, attributes)

        @remediation_policy = policy || RemediationPolicy.new(name: name || :remediation_policy, **attributes)
        self
      end

      def transport(name = nil, seam: nil, &block)
        return @transport_name if seam_query?(name, seam, block)

        configure_named_seam(:transport, name, seam, block, %i[call])
        self
      end

      def router(name = nil, seam: nil, &block)
        return @router_name if seam_query?(name, seam, block)

        configure_named_seam(:router, name, seam, block, %i[route])
        @route_policy = nil if seam || block
        self
      end

      def admission(name = nil, seam: nil, &block)
        return @admission_name if seam_query?(name, seam, block)

        configure_named_seam(:admission, name, seam, block, %i[admit])
        @admission_policy = nil if seam || block
        self
      end

      def placement(name = nil, seam: nil, &block)
        return @placement_name if seam_query?(name, seam, block)

        configure_named_seam(:placement, name, seam, block, %i[place])
        @placement_policy = nil if seam || block
        self
      end

      def peer_registry(name = nil, seam: nil, &block)
        return @peer_registry_name if seam_query?(name, seam, block)

        configure_named_seam(:peer_registry, name, seam, block, %i[register fetch peers])
        self
      end

      def incident_registry(name = nil, seam: nil, &block)
        return @incident_registry_name if seam_query?(name, seam, block)

        configure_named_seam(
          :incident_registry,
          name,
          seam,
          block,
          %i[record fetch entries active_set record_action workflow workflows]
        )
        self
      end

      def initialize_defaults
        @capability_catalog = CapabilityCatalog.new
        configure_default_seam(:transport, :direct, TransportAdapter.new)
        @route_policy = RoutePolicy.capability
        configure_default_seam(:router, @route_policy.name, PolicyRouter.new(policy: @route_policy))
        @admission_policy = AdmissionPolicy.permissive
        configure_default_seam(:admission, @admission_policy.name, PolicyAdmission.new(policy: @admission_policy))
        @placement_policy = PlacementPolicy.direct
        configure_default_seam(:placement, @placement_policy.name, PolicyPlacement.new(policy: @placement_policy))
        @topology_policy = TopologyPolicy.locality_aware
        @ownership_policy = OwnershipPolicy.distributed
        @lease_policy = LeasePolicy.ephemeral
        @health_policy = HealthPolicy.availability_aware
        @remediation_policy = RemediationPolicy.default
        configure_default_seam(:peer_registry, :memory, MemoryPeerRegistry.new)
        configure_default_seam(:incident_registry, :memory, MemoryIncidentRegistry.new)
      end

      def profile_names
        {
          transport: transport,
          router: router,
          admission: admission,
          placement: placement,
          peer_registry: peer_registry,
          incident_registry: incident_registry
        }
      end

      def profile_seams
        {
          transport: transport_seam,
          router: router_seam,
          admission: admission_seam,
          placement: placement_seam,
          peer_registry: peer_registry_seam,
          incident_registry: incident_registry_seam
        }
      end

      def profile_policies
        {
          route: @route_policy,
          admission: @admission_policy,
          placement: @placement_policy,
          topology: @topology_policy,
          ownership: @ownership_policy,
          lease: @lease_policy,
          health: @health_policy,
          remediation: @remediation_policy
        }
      end

      private

      def definition_query?(name, definition, attributes)
        !name.nil? && definition.nil? && attributes.empty?
      end

      def policy_query?(name, policy, attributes)
        name.nil? && policy.nil? && attributes.empty?
      end

      def seam_query?(name, seam, block)
        name.nil? && seam.nil? && !block
      end

      def configure_default_seam(type, name, seam)
        instance_variable_set(seam_name_ivar(type), name)
        instance_variable_set(seam_object_ivar(type), seam)
      end

      def configure_named_seam(type, next_name, explicit_seam, block, required_methods)
        current_seam = instance_variable_get(seam_object_ivar(type))
        instance_variable_set(seam_name_ivar(type), normalize_seam_name(type, next_name))
        instance_variable_set(
          seam_object_ivar(type),
          resolved_seam(type, explicit_seam, block, current_seam, required_methods)
        )
      end

      def normalize_seam_name(type, next_name)
        current_name = instance_variable_get(seam_name_ivar(type))
        next_name.nil? ? current_name : next_name.to_sym
      end

      def seam_name_ivar(type)
        "@#{type}_name"
      end

      def seam_object_ivar(type)
        "@#{type}_seam"
      end

      def seam_label(type)
        type.to_s.tr("_", " ")
      end

      def resolved_seam(type, explicit_seam, block, current_seam, required_methods)
        resolve_seam(
          explicit_seam,
          block,
          current: current_seam,
          required_methods: required_methods,
          label: seam_label(type)
        )
      end

      def resolve_seam(explicit_seam, block, current:, required_methods:, label:)
        resolved = explicit_seam || block || current
        missing = required_methods.reject { |method_name| resolved.respond_to?(method_name) }
        return resolved if missing.empty?

        raise ArgumentError, "#{label} seam #{resolved.inspect} must respond to: #{required_methods.join(", ")}"
      end
    end
  end
end
