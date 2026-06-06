# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationLoadPath
      attr_reader :group, :path, :absolute_path, :kind, :status, :metadata

      def initialize(group:, path:, absolute_path:, kind:, status:, metadata: {})
        @group = group.to_sym
        @path = path.to_s.freeze
        @absolute_path = absolute_path.to_s.freeze
        @kind = kind.to_sym
        @status = status.to_sym
        @metadata = metadata.dup.freeze
        freeze
      end

      def present?
        status == :present
      end

      def missing?
        status == :missing
      end

      def to_h
        {
          group: group,
          path: path,
          absolute_path: absolute_path,
          kind: kind,
          status: status,
          metadata: metadata.dup
        }
      end
    end
  end
end
