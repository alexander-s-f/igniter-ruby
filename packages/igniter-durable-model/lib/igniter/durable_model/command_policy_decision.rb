# frozen_string_literal: true

module Igniter
  module DurableModel
    # App-safe command policy summary. It is inspectable metadata, not an
    # authorization token and not a Ledger-side policy executor.
    class CommandPolicyDecision
      attr_reader :schema_version, :kind, :status, :owner, :command,
                  :subject_key, :operation, :actor, :required_capabilities,
                  :granted_capabilities, :missing_capabilities,
                  :review_required, :errors, :warnings, :metadata,
                  :execution_boundary

      def initialize(owner:, command:, subject_key:, operation:, status:,
                     actor: nil, required_capabilities: [],
                     granted_capabilities: [], missing_capabilities: [],
                     review_required: false, errors: [], warnings: [],
                     metadata: {}, schema_version: 1,
                     kind: :command_policy_decision,
                     execution_boundary: :app)
        @schema_version = schema_version
        @kind = token(kind)
        @status = token(status)
        @owner = token(owner)
        @command = token(command)
        @subject_key = subject_key
        @operation = token(operation)
        @actor = actor
        @required_capabilities = tokens(required_capabilities).freeze
        @granted_capabilities = tokens(granted_capabilities).freeze
        @missing_capabilities = tokens(missing_capabilities).freeze
        @review_required = !!review_required
        @errors = Array(errors).map { |entry| normalize_value(entry) }.freeze
        @warnings = Array(warnings).map { |entry| normalize_value(entry) }.freeze
        @metadata = normalize_hash(metadata).freeze
        @execution_boundary = token(execution_boundary)
        freeze
      end

      def allowed? = status == :allowed

      def denied? = status == :denied

      def review_required? = status == :review_required

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          status: status,
          owner: owner,
          command: command,
          subject_key: subject_key,
          operation: operation,
          actor: actor,
          required_capabilities: required_capabilities,
          granted_capabilities: granted_capabilities,
          missing_capabilities: missing_capabilities,
          review_required: review_required,
          errors: errors,
          warnings: warnings,
          metadata: metadata,
          execution_boundary: execution_boundary
        }
      end

      private

      def normalize_hash(value)
        return {} if value.nil?
        return value unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, entry), acc|
          acc[token(key)] = normalize_value(entry)
        end
      end

      def normalize_value(value)
        case value
        when Hash
          normalize_hash(value).freeze
        when Array
          value.map { |entry| normalize_value(entry) }.freeze
        else
          value
        end
      end

      def tokens(values)
        Array(values).map { |value| token(value) }
      end

      def token(value)
        value.is_a?(String) ? value.to_sym : value
      end
    end
  end
end
