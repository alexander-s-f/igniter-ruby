# frozen_string_literal: true

module Igniter
  module Cluster
    class AdmissionPolicy
      attr_reader :name, :allowed_peers, :blocked_peers, :required_query_capabilities,
                  :required_route_capabilities, :allow_empty_query, :metadata

      def initialize(name:, allowed_peers: nil, blocked_peers: [], required_query_capabilities: [],
                     required_route_capabilities: [], allow_empty_query: true, metadata: {})
        @name = name.to_sym
        @allowed_peers = normalize_optional_names(allowed_peers)
        @blocked_peers = normalize_names(blocked_peers)
        @required_query_capabilities = normalize_names(required_query_capabilities)
        @required_route_capabilities = normalize_names(required_route_capabilities)
        @allow_empty_query = allow_empty_query == true
        @metadata = metadata.dup.freeze
        freeze
      end

      def self.permissive(metadata: {})
        new(name: :permissive, metadata: metadata)
      end

      def admit(request:, route:)
        return denied_empty_query(request) if !allow_empty_query && request.query.empty?
        return denied_blocked_peer(request, route) if blocked_peers.include?(route.peer.name)
        return denied_unlisted_peer(request, route) unless allowed_peer?(route.peer.name)
        return denied_query_capabilities(request, route) unless query_capabilities_allowed?(request.query)
        return denied_route_capabilities(request, route) unless route_capabilities_allowed?(route.peer)

        accepted_code, accepted_message = accepted_reason_for(request)
        AdmissionResult.allowed(
          code: :accepted,
          metadata: result_metadata(request, route),
          reason: DecisionExplanation.new(
            code: accepted_code,
            message: accepted_message,
            metadata: result_metadata(request, route)
          )
        )
      end

      def to_h
        {
          name: name,
          allowed_peers: allowed_peers&.dup,
          blocked_peers: blocked_peers.dup,
          required_query_capabilities: required_query_capabilities.dup,
          required_route_capabilities: required_route_capabilities.dup,
          allow_empty_query: allow_empty_query,
          metadata: metadata.dup
        }
      end

      private

      def normalize_names(values)
        Array(values).map(&:to_sym).uniq.sort.freeze
      end

      def normalize_optional_names(values)
        return nil if values.nil?

        normalize_names(values)
      end

      def allowed_peer?(peer_name)
        return true if allowed_peers.nil?

        allowed_peers.include?(peer_name)
      end

      def query_capabilities_allowed?(query)
        required_query_capabilities.all? do |capability|
          query.required_capabilities.include?(capability)
        end
      end

      def route_capabilities_allowed?(peer)
        peer.supports_capabilities?(required_route_capabilities)
      end

      def denied_empty_query(request)
        denied_result(
          request,
          code: :empty_query_denied,
          message: "admission policy #{name} rejected empty query"
        )
      end

      def denied_blocked_peer(request, route)
        denied_result(
          request,
          route: route,
          code: :blocked_peer,
          message: "admission policy #{name} blocked peer #{route.peer.name}"
        )
      end

      def denied_unlisted_peer(request, route)
        denied_result(
          request,
          route: route,
          code: :unlisted_peer,
          message: "admission policy #{name} rejected peer #{route.peer.name}"
        )
      end

      def denied_query_capabilities(request, route)
        denied_result(
          request,
          route: route,
          code: :missing_query_capabilities,
          message: "admission policy #{name} requires query capabilities #{required_query_capabilities.inspect}"
        )
      end

      def denied_route_capabilities(request, route)
        denied_result(
          request,
          route: route,
          code: :missing_route_capabilities,
          message: "admission policy #{name} requires route capabilities #{required_route_capabilities.inspect}"
        )
      end

      def denied_result(request, code:, message:, route: nil)
        details = result_metadata(request, route)
        AdmissionResult.denied(
          code: code,
          metadata: details,
          reason: DecisionExplanation.new(
            code: code,
            message: message,
            metadata: details
          )
        )
      end

      def accepted_reason_for(request)
        return [:permissive_accept, "permissive admission accepted #{request.session_id}"] if name == :permissive

        [:policy_accept, "admission policy #{name} accepted #{request.session_id}"]
      end

      def result_metadata(request, route)
        {
          policy: name,
          session_id: request.session_id,
          peer: route&.peer&.name,
          peer_view: route&.peer_view&.to_h,
          peer_profile: route&.peer&.profile&.to_h
        }.compact
      end
    end
  end
end
