# frozen_string_literal: true

module Igniter
  module Application
    class MountRegistration
      attr_reader :name, :kind, :target, :at, :capabilities, :metadata

      def initialize(name:, target:, kind: :generic, at: nil, capabilities: [], metadata: {})
        raise ArgumentError, "mount target is required" if target.nil?

        @name = name.to_sym
        @kind = kind.to_sym
        @target = target
        @at = normalize_path(at)
        @capabilities = Array(capabilities).map(&:to_sym).sort.freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def target_name
        if target.respond_to?(:name) && !target.name.to_s.empty?
          target.name.to_s
        else
          target.class.name || target.inspect
        end
      end

      def to_h
        {
          name: name,
          kind: kind,
          target: target_name,
          at: at,
          capabilities: capabilities.dup,
          metadata: metadata.dup
        }
      end

      private

      def normalize_path(path)
        return nil if path.nil?

        value = path.to_s
        value.start_with?("/") ? value : "/#{value}"
      end
    end
  end
end
