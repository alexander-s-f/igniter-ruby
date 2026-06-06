# frozen_string_literal: true

module Igniter
  module Application
    class CapsuleExport
      attr_reader :name, :kind, :target, :metadata

      def initialize(name:, kind: :service, target: nil, metadata: {})
        @name = name.to_sym
        @kind = kind.to_sym
        @target = target&.to_s
        @metadata = metadata.dup.freeze
        freeze
      end

      def to_h
        {
          name: name,
          kind: kind,
          target: target,
          metadata: metadata.dup
        }.compact
      end
    end
  end
end
