# frozen_string_literal: true

module Igniter
  module Application
    class LifecyclePlanStep
      attr_reader :name, :seam_name, :action, :status, :metadata, :reason

      def initialize(name:, seam_name:, action:, status:, metadata: {}, reason: nil)
        @name = name.to_sym
        @seam_name = seam_name.to_sym
        @action = action.to_sym
        @status = status.to_sym
        @metadata = metadata.dup.freeze
        @reason = reason&.to_s
        freeze
      end

      def planned?
        status == :planned
      end

      def skipped?
        status == :skipped
      end

      def to_h
        {
          name: name,
          seam: seam_name,
          action: action,
          status: status,
          metadata: metadata.dup,
          reason: reason
        }
      end
    end
  end
end
