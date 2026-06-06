# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationTransferReceipt
      attr_reader :verification_payload, :result_payload, :plan_payload, :metadata, :manual_actions

      def self.build(applied_verification, apply_result: nil, apply_plan: nil, metadata: {})
        new(
          applied_verification: applied_verification,
          apply_result: apply_result,
          apply_plan: apply_plan,
          metadata: metadata
        )
      end

      def initialize(applied_verification:, apply_result: nil, apply_plan: nil, metadata: {})
        @verification_payload = payload_from(applied_verification)
        @result_payload = apply_result ? payload_from(apply_result) : nil
        @plan_payload = apply_plan ? payload_from(apply_plan) : nil
        @metadata = metadata.dup.freeze
        @manual_actions = dedupe_manual_actions(plan_manual_actions + skipped_manual_actions).freeze
        freeze
      end

      def complete?
        valid? && committed? && findings.empty? && refusals.empty? && skipped.empty? && manual_actions.empty?
      end

      def valid?
        value(verification_payload, :valid) == true
      end

      def committed?
        value(verification_payload, :committed) == true
      end

      def to_h
        {
          complete: complete?,
          valid: valid?,
          committed: committed?,
          artifact_path: artifact_path,
          destination_root: destination_root,
          counts: counts,
          manual_actions: manual_actions,
          findings: findings,
          refusals: refusals,
          skipped: skipped,
          agent_capabilities: agent_capabilities,
          surface_count: surface_count,
          metadata: metadata.dup
        }
      end

      private

      def counts
        {
          planned: planned_count,
          applied: applied.length,
          verified: verified.length,
          findings: findings.length,
          refusals: refusals.length,
          skipped: skipped.length,
          manual_actions: manual_actions.length
        }
      end

      def planned_count
        return value(plan_payload, :operation_count) if plan_payload && value(plan_payload, :operation_count)

        value(verification_payload, :operation_count) || verified.length + skipped.length
      end

      def plan_manual_actions
        return [] unless plan_payload

        actions = Array(value(plan_payload, :operations)).select do |operation|
          operation_type(operation) == :manual_host_wiring
        end
        actions.map { |operation| manual_action(operation, source_report: :apply_plan) }
      end

      def skipped_manual_actions
        skipped.select { |entry| operation_type(entry) == :manual_host_wiring }.map do |entry|
          manual_action(entry, source_report: :apply_result)
        end
      end

      def manual_action(entry, source_report:)
        {
          type: operation_type(entry),
          status: value(entry, :status),
          source: value(entry, :source),
          destination: value(entry, :destination),
          reason: value(entry, :reason),
          metadata: operation_metadata(entry),
          source_report: source_report
        }.compact
      end

      def dedupe_manual_actions(entries)
        entries.each_with_object({}) do |entry, by_signature|
          by_signature[
            [
              entry.fetch(:type),
              entry[:source].to_s,
              entry[:destination].to_s,
              entry[:metadata].to_s
            ]
          ] ||= entry
        end.values
      end

      def applied
        return [] unless result_payload

        Array(value(result_payload, :applied))
      end

      def verified
        Array(value(verification_payload, :verified))
      end

      def findings
        Array(value(verification_payload, :findings)).map(&:dup)
      end

      def refusals
        Array(value(verification_payload, :refusals)).map(&:dup)
      end

      def skipped
        Array(value(verification_payload, :skipped)).map(&:dup)
      end

      def artifact_path
        value(verification_payload, :artifact_path)
      end

      def destination_root
        value(verification_payload, :destination_root)
      end

      def surface_count
        value(verification_payload, :surface_count) || 0
      end

      def agent_capabilities
        return [] unless plan_payload

        Array(value(plan_payload, :agent_capabilities)).map(&:dup)
      end

      def operation_type(entry)
        type = value(entry, :type)
        type.respond_to?(:to_sym) ? type.to_sym : type
      end

      def operation_metadata(entry)
        data = value(entry, :metadata)
        data.respond_to?(:dup) ? data.dup : data
      end

      def payload_from(source)
        payload = source.respond_to?(:to_h) ? source.to_h : source
        payload.to_h
      end

      def value(hash, key)
        return nil unless hash.respond_to?(:key?)
        return hash[key] if hash.key?(key)

        hash[key.to_s]
      end
    end
  end
end
