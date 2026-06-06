# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationHostActivationPlanVerification
      ALLOWED_OPERATION_TYPES = %i[
        confirm_host_export
        confirm_host_capability
        confirm_load_path
        confirm_provider
        confirm_contract
        confirm_lifecycle
        acknowledge_manual_actions
        review_mount_intent
      ].freeze

      REVIEW_STATUS = :review_required

      attr_reader :plan_payload, :metadata

      def self.verify(plan, metadata: {})
        new(plan: plan, metadata: metadata)
      end

      def initialize(plan:, metadata: {})
        @plan_payload = payload_from(plan).freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def valid?
        findings.empty?
      end

      def to_h
        {
          valid: valid?,
          executable: executable?,
          verified: verified_operations,
          findings: findings,
          operation_count: operations.length,
          surface_count: surface_count,
          metadata: metadata.dup
        }
      end

      private

      def findings
        [].tap do |items|
          items << finding(:executable_plan_without_operations, "Executable activation plans should carry review operations.", plan_payload) if
            executable? && operations.empty? && !allow_empty_operations?
          items << finding(:non_executable_plan_without_blockers, "Non-executable activation plans should carry blockers.", plan_payload) if
            !executable? && blockers.empty?
          items << finding(:non_executable_plan_with_operations, "Non-executable activation plans must not carry operations.", operations) if
            !executable? && !operations.empty?

          operations.each do |operation|
            items.concat(operation_findings(operation))
          end
        end
      end

      def operation_findings(operation)
        [].tap do |items|
          type = comparable(value(operation, :type)).to_sym
          status = comparable(value(operation, :status)).to_sym

          items << finding(:unknown_operation_type, "Activation plan operation type is not descriptive.", operation) unless
            ALLOWED_OPERATION_TYPES.include?(type)
          items << finding(:operation_not_review_required, "Activation plan operation must remain review-only.", operation) unless
            status == REVIEW_STATUS
          items << finding(:mount_intent_metadata_missing, "Mount review operation must carry supplied intent metadata only.", operation) if
            type == :review_mount_intent && !value(metadata_for(operation), :intent).is_a?(Hash)
        end
      end

      def verified_operations
        return [] unless valid?

        operations.map(&:dup)
      end

      def executable?
        value(plan_payload, :executable) == true
      end

      def allow_empty_operations?
        policy = normalize_hash(value(plan_payload, :policy))
        plan_metadata = normalize_hash(value(plan_payload, :metadata))
        value(policy, :allow_empty_operations) == true || value(plan_metadata, :allow_empty_operations) == true
      end

      def operations
        Array(value(plan_payload, :operations)).map { |entry| normalize_hash(entry) }
      end

      def blockers
        Array(value(plan_payload, :blockers)).map { |entry| normalize_hash(entry) }
      end

      def surface_count
        value(plan_payload, :surface_count) || 0
      end

      def metadata_for(operation)
        normalize_hash(value(operation, :metadata))
      end

      def finding(code, message, entry)
        {
          code: code,
          message: message,
          entry: entry
        }
      end

      def payload_from(source)
        payload = source.respond_to?(:to_h) ? source.to_h : source
        normalize_hash(payload)
      end

      def normalize_hash(value)
        source = value.respond_to?(:to_h) ? value.to_h : {}
        source.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end

      def comparable(value)
        value.to_s
      end

      def value(hash, key)
        return nil unless hash.respond_to?(:key?)
        return hash[key] if hash.key?(key)

        hash[key.to_s]
      end
    end
  end
end
