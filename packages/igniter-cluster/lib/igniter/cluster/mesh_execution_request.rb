# frozen_string_literal: true

module Igniter
  module Cluster
    class MeshExecutionRequest
      attr_reader :trace_id, :plan_kind, :action_type, :subject, :action, :metadata

      def initialize(trace_id:, plan_kind:, action_type:, subject:, action:, metadata: {})
        @trace_id = trace_id.to_s
        @plan_kind = plan_kind.to_sym
        @action_type = action_type.to_sym
        @subject = deep_freeze(normalize_hash(subject))
        @action = deep_freeze(normalize_hash(action))
        @metadata = deep_freeze(normalize_hash(metadata))
        freeze
      end

      def to_h
        {
          trace_id: trace_id,
          plan_kind: plan_kind,
          action_type: action_type,
          subject: deep_dup(subject),
          action: deep_dup(action),
          metadata: deep_dup(metadata)
        }
      end

      private

      def normalize_hash(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), memo|
            memo[key.to_sym] = normalize_hash(entry)
          end
        when Array
          value.map { |entry| normalize_hash(entry) }
        else
          value
        end
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), memo|
            memo[key] = deep_freeze(entry)
          end.freeze
        when Array
          value.map { |entry| deep_freeze(entry) }.freeze
        else
          value.freeze
        end
      end

      def deep_dup(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), memo|
            memo[key] = deep_dup(entry)
          end
        when Array
          value.map { |entry| deep_dup(entry) }
        else
          value
        end
      end
    end
  end
end
