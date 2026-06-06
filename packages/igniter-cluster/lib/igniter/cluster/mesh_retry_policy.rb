# frozen_string_literal: true

module Igniter
  module Cluster
    class MeshRetryPolicy
      attr_reader :name, :max_attempts, :fallback_on_failure, :retry_statuses, :allow_degraded, :metadata

      def initialize(name:, max_attempts: nil, fallback_on_failure: true, retry_statuses: [:failed],
                     allow_degraded: false, metadata: {})
        @name = name.to_sym
        @max_attempts = max_attempts.nil? ? nil : Integer(max_attempts)
        @fallback_on_failure = fallback_on_failure == true
        @retry_statuses = Array(retry_statuses).map(&:to_sym).uniq.sort.freeze
        @allow_degraded = allow_degraded == true
        @metadata = metadata.dup.freeze
        freeze
      end

      def candidate_peers(peers)
        candidates = Array(peers)
        return candidates if max_attempts.nil?

        candidates.first(max_attempts)
      end

      def retryable_status?(status)
        fallback_on_failure && retry_statuses.include?(status.to_sym)
      end

      def to_h
        {
          name: name,
          max_attempts: max_attempts,
          fallback_on_failure: fallback_on_failure,
          retry_statuses: retry_statuses.dup,
          allow_degraded: allow_degraded,
          metadata: metadata.dup
        }
      end
    end
  end
end
