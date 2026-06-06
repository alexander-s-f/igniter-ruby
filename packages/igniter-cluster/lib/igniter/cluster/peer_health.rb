# frozen_string_literal: true

require "time"

module Igniter
  module Cluster
    class PeerHealth
      attr_reader :status, :checks, :observed_at, :metadata

      def initialize(status: :healthy, checks: {}, observed_at: Time.now.utc, metadata: {})
        @status = status.to_sym
        @checks = normalize_checks(checks)
        @observed_at = observed_at
        @metadata = metadata.dup.freeze
        freeze
      end

      def healthy?
        status == :healthy
      end

      def degraded?
        status == :degraded
      end

      def unhealthy?
        status == :unhealthy
      end

      def available?(allow_degraded: false)
        return true if healthy?
        return true if degraded? && allow_degraded

        false
      end

      def to_h
        {
          status: status,
          checks: checks.dup,
          observed_at: observed_at.iso8601,
          metadata: metadata.dup
        }
      end

      private

      def normalize_checks(checks)
        checks.each_with_object({}) do |(key, value), memo|
          memo[key.to_sym] = value
        end.freeze
      end
    end
  end
end
