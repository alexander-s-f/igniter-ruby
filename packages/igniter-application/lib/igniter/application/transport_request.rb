# frozen_string_literal: true

module Igniter
  module Application
    class TransportRequest
      attr_reader :session_id, :kind, :operation_name, :compiled_graph,
                  :inputs, :items, :key_name, :window, :metadata, :profile_fingerprint

      def initialize(session_id:, kind:, operation_name:, compiled_graph:, inputs:, profile_fingerprint:, items: nil,
                     key_name: nil, window: nil, metadata: {})
        @session_id = session_id.to_s
        @kind = kind.to_sym
        @operation_name = operation_name.to_sym
        @compiled_graph = compiled_graph
        @inputs = inputs.transform_keys(&:to_sym).freeze
        @items = items.nil? ? nil : Array(items).freeze
        @key_name = key_name&.to_sym
        @window = window
        @metadata = metadata.dup.freeze
        @profile_fingerprint = profile_fingerprint
        freeze
      end

      def to_h
        {
          session_id: session_id,
          kind: kind,
          operation_name: operation_name,
          compiled_graph: compiled_graph.to_h,
          inputs: inputs.dup,
          items: items&.dup,
          key_name: key_name,
          window: window,
          metadata: metadata.dup,
          profile_fingerprint: profile_fingerprint
        }
      end
    end
  end
end
