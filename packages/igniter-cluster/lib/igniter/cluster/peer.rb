# frozen_string_literal: true

module Igniter
  module Cluster
    class Peer
      attr_reader :profile, :transport

      def initialize(name:, capabilities:, transport:, metadata: {}, roles: [], labels: {}, region: nil, zone: nil,
                     profile: nil, capability_catalog: nil, health: nil, health_status: :healthy, health_checks: {})
        raise ArgumentError, "peer transport must respond to call(request:)" unless transport.respond_to?(:call)

        @profile = profile || PeerProfile.new(
          name: name,
          capabilities: capabilities,
          roles: roles,
          labels: labels,
          region: region,
          zone: zone,
          metadata: metadata,
          capability_catalog: capability_catalog,
          health: health,
          health_status: health_status,
          health_checks: health_checks
        )
        @transport = transport
        freeze
      end

      def name
        profile.name
      end

      def capabilities
        profile.capabilities
      end

      def roles
        profile.roles
      end

      def labels
        profile.labels
      end

      def region
        profile.region
      end

      def zone
        profile.zone
      end

      def metadata
        profile.metadata
      end

      def health
        profile.health
      end

      def supports_capabilities?(required_capabilities)
        profile.supports_capabilities?(required_capabilities)
      end

      def supports_traits?(required_traits)
        profile.supports_traits?(required_traits)
      end

      def matches_labels?(required_labels)
        profile.matches_labels?(required_labels)
      end

      def matches_region?(preferred_region)
        profile.matches_region?(preferred_region)
      end

      def matches_zone?(preferred_zone)
        profile.matches_zone?(preferred_zone)
      end

      def to_h
        profile.to_h
      end
    end
  end
end
