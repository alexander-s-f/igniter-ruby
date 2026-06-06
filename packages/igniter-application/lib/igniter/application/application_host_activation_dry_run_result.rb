# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationHostActivationDryRunResult
      APPLICATION_OPERATION_TYPES = %i[
        confirm_load_path
        confirm_provider
        confirm_contract
        confirm_lifecycle
      ].freeze

      HOST_OWNED_OPERATION_TYPES = %i[
        confirm_host_export
        confirm_host_capability
      ].freeze

      MANUAL_OPERATION_TYPES = %i[
        acknowledge_manual_actions
      ].freeze

      MOUNT_OPERATION_TYPES = %i[
        review_mount_intent
      ].freeze

      attr_reader :verification_payload, :host_target, :metadata

      def self.dry_run(verification, host_target: nil, metadata: {})
        new(verification: verification, host_target: host_target, metadata: metadata)
      end

      def initialize(verification:, host_target: nil, metadata: {})
        @verification_payload = payload_from(verification).freeze
        @host_target = host_target
        @metadata = metadata.dup.freeze
        freeze
      end

      def executable?
        refusals.empty?
      end

      def to_h
        {
          dry_run: true,
          committed: false,
          executable: executable?,
          would_apply: would_apply,
          skipped: skipped,
          refusals: refusals,
          warnings: warnings,
          surface_count: surface_count,
          metadata: metadata.dup
        }
      end

      private

      def would_apply
        return [] unless executable?

        application_operations.map do |operation|
          operation_result(operation, :dry_run, target: host_target)
        end
      end

      def skipped
        verified_operations.filter_map do |operation|
          reason = skip_reason(operation)
          operation_result(operation, :skipped, reason: reason) if reason
        end
      end

      def refusals
        [].tap do |items|
          items << refusal(:verification_invalid, "Activation plan verification is not valid.", entry: findings) unless
            verification_valid?
          items << refusal(:plan_not_executable, "Activation plan is not executable.", entry: verification_payload) unless
            plan_executable?
          items << refusal(:missing_host_target, "Application-owned dry-run operations require an explicit host target.", entry: application_operations) if
            application_operations.any? && missing_host_target?
          unsupported_operations.each do |operation|
            items << refusal(:unsupported_operation, "Activation dry-run operation type is not supported.", entry: operation)
          end
        end
      end

      def warnings
        []
      end

      def skip_reason(operation)
        type = operation_type(operation)
        return :host_owned_evidence if HOST_OWNED_OPERATION_TYPES.include?(type)
        return :manual_host_action if MANUAL_OPERATION_TYPES.include?(type)
        return :web_or_host_owned_mount if MOUNT_OPERATION_TYPES.include?(type)
        return :missing_host_target if APPLICATION_OPERATION_TYPES.include?(type) && missing_host_target?
        return :unsupported_operation unless APPLICATION_OPERATION_TYPES.include?(type)

        nil
      end

      def operation_result(operation, status, reason: nil, target: nil)
        {
          type: operation_type(operation),
          status: status,
          source: value(operation, :source),
          destination: value(operation, :destination),
          metadata: operation_metadata(operation),
          reason: reason,
          target: target
        }.compact
      end

      def application_operations
        verified_operations.select { |operation| APPLICATION_OPERATION_TYPES.include?(operation_type(operation)) }
      end

      def unsupported_operations
        verified_operations.reject do |operation|
          (
            APPLICATION_OPERATION_TYPES +
            HOST_OWNED_OPERATION_TYPES +
            MANUAL_OPERATION_TYPES +
            MOUNT_OPERATION_TYPES
          ).include?(operation_type(operation))
        end
      end

      def verification_valid?
        value(verification_payload, :valid) == true
      end

      def plan_executable?
        value(verification_payload, :executable) == true
      end

      def missing_host_target?
        host_target.to_s.empty?
      end

      def verified_operations
        Array(value(verification_payload, :verified)).map { |entry| normalize_hash(entry) }
      end

      def findings
        Array(value(verification_payload, :findings)).map { |entry| normalize_hash(entry) }
      end

      def surface_count
        value(verification_payload, :surface_count) || 0
      end

      def operation_type(operation)
        type = value(operation, :type)
        type.respond_to?(:to_sym) ? type.to_sym : type
      end

      def operation_metadata(operation)
        metadata = value(operation, :metadata)
        metadata.respond_to?(:dup) ? metadata.dup : metadata
      end

      def payload_from(source)
        payload = source.respond_to?(:to_h) ? source.to_h : source
        normalize_hash(payload)
      end

      def normalize_hash(value)
        source = value.respond_to?(:to_h) ? value.to_h : {}
        source.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end

      def value(hash, key)
        return nil unless hash.respond_to?(:key?)
        return hash[key] if hash.key?(key)

        hash[key.to_s]
      end

      def refusal(code, message, entry:)
        {
          code: code,
          message: message,
          entry: entry
        }
      end
    end
  end
end
