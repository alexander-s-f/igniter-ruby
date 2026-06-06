# frozen_string_literal: true

module Igniter
  module Application
    class CapsuleImport
      attr_reader :name, :kind, :from, :optional, :capabilities, :metadata

      def initialize(name:, kind: :service, from: nil, optional: false, capabilities: [], metadata: {})
        @name = name.to_sym
        @kind = kind.to_sym
        @from = from&.to_sym
        @optional = optional == true
        @capabilities = Array(capabilities).map(&:to_sym).sort.freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def optional?
        optional
      end

      def required?
        !optional?
      end

      def to_h
        {
          name: name,
          kind: kind,
          from: from,
          optional: optional?,
          capabilities: capabilities.dup,
          metadata: metadata.dup
        }.compact
      end
    end
  end
end
