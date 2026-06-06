# frozen_string_literal: true

module Igniter
  module Application
    class CollectionTransportAdapter
      def initialize(transport:, metadata: {})
        @transport = transport
        @metadata = metadata.dup.freeze
      end

      def with_metadata(additions)
        self.class.new(transport: transport, metadata: metadata.merge(additions))
      end

      def call(invocation:)
        transport.call(
          request: TransportRequest.new(
            session_id: metadata.fetch(:session_id),
            kind: :collection,
            operation_name: invocation.operation.name,
            compiled_graph: invocation.compiled_graph,
            inputs: invocation.inputs,
            items: invocation.items,
            key_name: invocation.key_name,
            window: invocation.window,
            profile_fingerprint: invocation.profile.fingerprint,
            metadata: metadata
          )
        )
      end

      private

      attr_reader :transport, :metadata
    end
  end
end
