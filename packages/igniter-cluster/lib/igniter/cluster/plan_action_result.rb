# frozen_string_literal: true

module Igniter
  module Cluster
    class PlanActionResult
      attr_reader :action_type, :status, :subject, :metadata, :explanation

      def initialize(action_type:, status:, subject:, metadata: {}, explanation: nil)
        @action_type = action_type.to_sym
        @status = status.to_sym
        @subject = normalize_subject(subject)
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: @status,
          metadata: @metadata
        )
        freeze
      end

      def completed?
        status == :completed
      end

      def failed?
        status == :failed
      end

      def skipped?
        status == :skipped
      end

      def to_h
        {
          action_type: action_type,
          status: status,
          subject: deep_dup(subject),
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end

      private

      def normalize_subject(subject)
        case subject
        when Hash
          subject.each_with_object({}) do |(key, value), memo|
            memo[key.to_sym] = normalize_subject(value)
          end.freeze
        when Array
          subject.map { |value| normalize_subject(value) }.freeze
        else
          subject
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
