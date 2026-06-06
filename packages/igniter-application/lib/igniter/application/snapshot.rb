# frozen_string_literal: true

module Igniter
  module Application
    class Snapshot
      attr_reader :profile, :runtime_state

      def initialize(profile:, runtime_state:)
        @profile = profile
        @runtime_state = runtime_state.dup.freeze
        freeze
      end

      def booted?
        runtime_state[:booted]
      end

      def code_loaded?
        runtime_state[:code_loaded]
      end

      def scheduler_running?
        runtime_state[:scheduler_running]
      end

      def transport_activated?
        runtime_state[:transport_activated]
      end

      def to_h
        profile.to_h.merge(runtime: runtime_state.dup)
      end
    end
  end
end
