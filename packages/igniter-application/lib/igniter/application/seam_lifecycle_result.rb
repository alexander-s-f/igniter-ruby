# frozen_string_literal: true

module Igniter
  module Application
    class SeamLifecycleResult
      attr_reader :seam_name, :action, :status, :metadata, :error

      def initialize(seam_name:, action:, status:, metadata: {}, error: nil)
        @seam_name = seam_name.to_sym
        @action = action.to_sym
        @status = status.to_sym
        @metadata = metadata.dup.freeze
        @error = normalize_error(error)
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
          seam: seam_name,
          action: action,
          status: status,
          metadata: metadata.dup,
          error: error&.dup
        }
      end

      def with_metadata(next_metadata)
        self.class.new(
          seam_name: seam_name,
          action: action,
          status: status,
          metadata: next_metadata,
          error: error
        )
      end

      private

      def normalize_error(error)
        return nil if error.nil?
        return error.dup.freeze if error.is_a?(Hash)

        {
          class: error.class.name,
          message: error.message
        }.freeze
      end
    end
  end
end
