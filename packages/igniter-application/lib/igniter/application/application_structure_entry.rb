# frozen_string_literal: true

require "fileutils"

module Igniter
  module Application
    class ApplicationStructureEntry
      attr_reader :group, :path, :absolute_path, :kind, :status, :action, :metadata

      def initialize(group:, path:, absolute_path:, kind:, status:, action:, metadata: {})
        @group = group.to_sym
        @path = path.to_s.freeze
        @absolute_path = absolute_path.to_s.freeze
        @kind = kind.to_sym
        @status = status.to_sym
        @action = action.to_sym
        @metadata = metadata.dup.freeze
        freeze
      end

      def present?
        status == :present
      end

      def missing?
        status == :missing
      end

      def apply!
        case action
        when :keep
          false
        when :create_directory
          FileUtils.mkdir_p(absolute_path)
          true
        when :write_file
          FileUtils.mkdir_p(File.dirname(absolute_path))
          File.write(absolute_path, metadata.fetch(:default_content, ""))
          true
        else
          raise ArgumentError, "unknown application structure action #{action.inspect}"
        end
      end

      def to_h
        {
          group: group,
          path: path,
          absolute_path: absolute_path,
          kind: kind,
          status: status,
          action: action,
          metadata: metadata.dup
        }
      end
    end
  end
end
