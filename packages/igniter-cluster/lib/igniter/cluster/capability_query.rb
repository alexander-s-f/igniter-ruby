# frozen_string_literal: true

module Igniter
  module Cluster
    class CapabilityQuery
      attr_reader :required_capabilities, :required_traits, :required_labels, :preferred_peer,
                  :preferred_region, :preferred_zone, :metadata, :capability_catalog

      def initialize(required_capabilities: [], required_traits: [], required_labels: {}, preferred_peer: nil,
                     preferred_region: nil, preferred_zone: nil, metadata: {}, capability_catalog: nil)
        @required_capabilities = Array(required_capabilities).map(&:to_sym).uniq.sort.freeze
        @required_traits = Array(required_traits).map(&:to_sym).uniq.sort.freeze
        @required_labels = normalize_labels(required_labels)
        @preferred_peer = preferred_peer&.to_sym
        @preferred_region = preferred_region&.to_s
        @preferred_zone = preferred_zone&.to_s
        @metadata = metadata.dup.freeze
        @capability_catalog = capability_catalog
        freeze
      end

      def self.from_routing(routing = nil, capability_catalog: nil, **keyword_routing)
        routing ||= keyword_routing
        new(
          required_capabilities: routing_capabilities(routing),
          required_traits: routing_traits(routing),
          required_labels: routing_labels(routing),
          preferred_peer: routing_peer(routing),
          preferred_region: routing_region(routing),
          preferred_zone: routing_zone(routing),
          metadata: routing_metadata(routing),
          capability_catalog: capability_catalog
        )
      end

      def pinned?
        !preferred_peer.nil?
      end

      def empty?
        !pinned? && !capability_constraints? && !topology_constraints?
      end

      def routing_mode
        return :pinned if pinned?
        return :capability if capability_constraints? || topology_constraints?

        :first_available
      end

      def capability_constraints?
        !required_capabilities.empty? || !required_traits.empty?
      end

      def topology_constraints?
        !required_labels.empty? || !preferred_region.nil? || !preferred_zone.nil?
      end

      def matches_peer?(peer, honor_preferred_peer: true, require_capabilities: true)
        return false if honor_preferred_peer && pinned? && peer.name != preferred_peer

        return false unless matches_topology?(peer)
        return true unless require_capabilities

        matches_capabilities?(peer)
      end

      def matches_capabilities?(peer)
        peer.supports_capabilities?(required_capabilities) &&
          peer.supports_traits?(required_traits)
      end

      def matches_topology?(peer)
        peer.matches_labels?(required_labels) &&
          peer.matches_region?(preferred_region) &&
          peer.matches_zone?(preferred_zone)
      end

      def capability_definitions
        return [] if capability_catalog.nil?

        capability_catalog.resolve(required_capabilities)
      end

      def required_trait_definitions
        return [] if capability_catalog.nil?

        capability_catalog.with_traits(required_traits)
      end

      def to_h
        {
          required_capabilities: required_capabilities.dup,
          required_capability_definitions: capability_definitions.map(&:to_h),
          required_traits: required_traits.dup,
          required_trait_definitions: required_trait_definitions.map(&:to_h),
          required_labels: required_labels.dup,
          preferred_peer: preferred_peer,
          preferred_region: preferred_region,
          preferred_zone: preferred_zone,
          metadata: metadata.dup
        }
      end

      class << self
        private

        def routing_capabilities(routing)
          routing.fetch(:required_capabilities, routing.fetch("required_capabilities", legacy_capabilities(routing)))
        end

        def routing_traits(routing)
          routing.fetch(:required_traits, routing.fetch("required_traits", []))
        end

        def routing_labels(routing)
          routing.fetch(:required_labels, routing.fetch("required_labels", {}))
        end

        def routing_peer(routing)
          routing.fetch(:preferred_peer, routing.fetch("preferred_peer", legacy_peer(routing)))
        end

        def routing_region(routing)
          routing.fetch(:preferred_region, routing.fetch("preferred_region", legacy_region(routing)))
        end

        def routing_zone(routing)
          routing.fetch(:preferred_zone, routing.fetch("preferred_zone", legacy_zone(routing)))
        end

        def routing_metadata(routing)
          routing.fetch(:metadata, routing.fetch("metadata", {}))
        end

        def legacy_capabilities(routing)
          routing.fetch(:all_of, routing.fetch("all_of", []))
        end

        def legacy_peer(routing)
          routing[:peer] || routing["peer"]
        end

        def legacy_region(routing)
          routing[:region] || routing["region"]
        end

        def legacy_zone(routing)
          routing[:zone] || routing["zone"]
        end
      end

      private

      def normalize_labels(labels)
        labels.each_with_object({}) do |(key, value), memo|
          memo[key.to_sym] = value
        end.freeze
      end
    end
  end
end
