# frozen_string_literal: true

module Igniter
  module Cluster
    class PeerProfile
      attr_reader :name, :capabilities, :roles, :topology, :health, :metadata, :capability_catalog

      def initialize(name:, capabilities:, roles: [], labels: {}, region: nil, zone: nil, metadata: {},
                     capability_catalog: nil, topology: nil, health: nil, health_status: :healthy, health_checks: {})
        @name = name.to_sym
        @capabilities = normalize_names(capabilities)
        @roles = normalize_names(roles)
        @metadata = metadata.dup.freeze
        @capability_catalog = capability_catalog
        @topology = topology || PeerTopology.new(region: region, zone: zone, labels: labels)
        @health = health || PeerHealth.new(status: health_status, checks: health_checks)
        freeze
      end

      def supports_capabilities?(required_capabilities)
        Array(required_capabilities).all? { |capability| capabilities.include?(capability.to_sym) }
      end

      def supports_traits?(required_traits)
        Array(required_traits).all? { |trait| capability_traits.include?(trait.to_sym) }
      end

      def label(name)
        topology.label(name)
      end

      def tagged?(name, value = nil)
        topology.tagged?(name, value)
      end

      def capability_definitions
        return [] if capability_catalog.nil?

        capability_catalog.resolve(capabilities)
      end

      def capability_traits
        capability_definitions.flat_map(&:traits).uniq.sort
      end

      def matches_labels?(required_labels)
        topology.matches_labels?(required_labels)
      end

      def matches_region?(preferred_region)
        topology.matches_region?(preferred_region)
      end

      def matches_zone?(preferred_zone)
        topology.matches_zone?(preferred_zone)
      end

      def satisfies_query?(query, require_capabilities: true)
        return false unless matches_labels?(query.required_labels)
        return false unless matches_region?(query.preferred_region)
        return false unless matches_zone?(query.preferred_zone)
        return true unless require_capabilities

        supports_capabilities?(query.required_capabilities) && supports_traits?(query.required_traits)
      end

      def to_h
        {
          name: name,
          capabilities: capabilities.dup,
          capability_definitions: capability_definitions.map(&:to_h),
          capability_traits: capability_traits,
          roles: roles.dup,
          topology: topology.to_h,
          health: health.to_h,
          labels: labels.dup,
          region: region,
          zone: zone,
          metadata: metadata.dup
        }
      end

      def labels
        topology.labels
      end

      def region
        topology.region
      end

      def zone
        topology.zone
      end

      private

      def normalize_names(values)
        Array(values).map(&:to_sym).uniq.sort.freeze
      end
    end
  end
end
