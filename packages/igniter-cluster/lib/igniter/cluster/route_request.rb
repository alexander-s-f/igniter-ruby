# frozen_string_literal: true

module Igniter
  module Cluster
    class RouteRequest
      attr_reader :session_id, :kind, :operation_name, :query, :metadata, :profile_fingerprint

      def initialize(attributes)
        @session_id = attributes.fetch(:session_id).to_s
        @kind = attributes.fetch(:kind).to_sym
        @operation_name = attributes.fetch(:operation_name).to_sym
        @query = attributes.fetch(:query)
        @metadata = attributes.fetch(:metadata).dup.freeze
        @profile_fingerprint = attributes.fetch(:profile_fingerprint)
        freeze
      end

      def self.from_transport_request(request, capability_catalog: nil)
        new(attributes_from_transport_request(request, capability_catalog: capability_catalog))
      end

      def to_h
        {
          session_id: session_id,
          kind: kind,
          operation_name: operation_name,
          query: query.to_h,
          metadata: metadata.dup,
          profile_fingerprint: profile_fingerprint
        }
      end

      def capabilities
        query.required_capabilities
      end

      def pinned_peer
        query.preferred_peer
      end

      class << self
        private

        def routing_metadata(request)
          request.metadata.fetch(:routing, request.metadata.fetch("routing", {}))
        end

        def attributes_from_transport_request(request, capability_catalog:)
          {
            session_id: request.session_id,
            kind: request.kind,
            operation_name: request.operation_name,
            query: CapabilityQuery.from_routing(routing_metadata(request), capability_catalog: capability_catalog),
            metadata: request.metadata,
            profile_fingerprint: request.profile_fingerprint
          }
        end
      end
    end
  end
end
