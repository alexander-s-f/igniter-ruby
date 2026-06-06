# frozen_string_literal: true

module Igniter
  module Contracts
    Error = Class.new(StandardError)

    class ValidationError < Error
      attr_reader :findings

      def initialize(message = nil, findings: [])
        @findings = Array(findings).freeze
        super(message || default_message)
      end

      private

      def default_message
        return "validation failed" if findings.empty?

        findings.map(&:message).join("; ")
      end

      public

      def to_h
        {
          message: message,
          findings: findings.map(&:to_h)
        }
      end
    end

    FrozenKernelError = Class.new(Error)
    FrozenRegistryError = Class.new(Error)
    DuplicateRegistrationError = Class.new(Error)
    UnknownDslKeywordError = Class.new(Error)
    UnknownNodeKindError = Class.new(Error)
    UnknownEffectError = Class.new(Error)
    UnknownExecutorError = Class.new(Error)
    ProfileMismatchError = Class.new(Error)
    IncompletePackError = Class.new(Error)
    UnknownPackDependencyError = Class.new(Error)
    CircularPackDependencyError = Class.new(Error)
    InvalidHookImplementationError = Class.new(Error)
    InvalidHookResultError = Class.new(Error)
  end
end
