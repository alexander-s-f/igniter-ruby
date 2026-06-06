# frozen_string_literal: true

module Igniter
  module Cluster
    class RoutePolicy
      attr_reader :name, :honor_preferred_peer, :require_capabilities, :allow_first_available, :metadata

      def initialize(name:, honor_preferred_peer: true, require_capabilities: true, allow_first_available: true,
                     metadata: {})
        @name = name.to_sym
        @honor_preferred_peer = honor_preferred_peer == true
        @require_capabilities = require_capabilities == true
        @allow_first_available = allow_first_available == true
        @metadata = metadata.dup.freeze
        freeze
      end

      def self.capability(metadata: {})
        new(name: :capability, metadata: metadata)
      end

      def route_mode_for(query)
        return :pinned if honor_preferred_peer && query.pinned?
        return :capability if query.capability_constraints? || query.topology_constraints?
        return :first_available if allow_first_available

        :unroutable
      end

      def select_peer(query:, candidates:)
        Array(candidates).find do |peer|
          matches_peer?(query, peer)
        end
      end

      def explanation_for(query:, peer:)
        mode = route_mode_for(query)

        case mode
        when :pinned
          DecisionExplanation.new(
            code: :pinned_route,
            message: "pinned route to #{peer.name}",
            metadata: {
              peer: peer.name,
              preferred_peer: query.preferred_peer,
              policy: name
            }
          )
        when :capability
          explanation_code, explanation_message = capability_explanation_for(query, peer)
          DecisionExplanation.new(
            code: explanation_code,
            message: explanation_message,
            metadata: {
              peer: peer.name,
              required_capabilities: query.required_capabilities,
              required_traits: query.required_traits,
              required_labels: query.required_labels,
              preferred_region: query.preferred_region,
              preferred_zone: query.preferred_zone,
              policy: name
            }
          )
        else
          DecisionExplanation.new(
            code: :first_available_route,
            message: "first available peer #{peer.name}",
            metadata: {
              peer: peer.name,
              policy: name
            }
          )
        end
      end

      def to_h
        {
          name: name,
          honor_preferred_peer: honor_preferred_peer,
          require_capabilities: require_capabilities,
          allow_first_available: allow_first_available,
          metadata: metadata.dup
        }
      end

      private

      def matches_peer?(query, peer)
        query.matches_peer?(
          peer,
          honor_preferred_peer: honor_preferred_peer,
          require_capabilities: require_capabilities
        )
      end

      def capability_explanation_for(query, peer)
        return [:capability_route, "capability route to #{peer.name}"] unless query.topology_constraints? || !query.required_traits.empty?

        [:intent_route, "intent route to #{peer.name}"]
      end
    end
  end
end
