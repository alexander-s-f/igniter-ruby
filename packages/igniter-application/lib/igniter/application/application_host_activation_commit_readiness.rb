# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationHostActivationCommitReadiness
      attr_reader :dry_run_payload, :provided_adapters, :metadata

      def self.build(dry_run, provided_adapters: [], metadata: {})
        new(dry_run: dry_run, provided_adapters: provided_adapters, metadata: metadata)
      end

      def initialize(dry_run:, provided_adapters: [], metadata: {})
        @dry_run_payload = payload_from(dry_run).freeze
        @provided_adapters = Array(provided_adapters).map { |entry| normalize_adapter(entry) }.freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def ready?
        blockers.empty?
      end

      def to_h
        {
          ready: ready?,
          commit_allowed: ready?,
          dry_run: dry_run?,
          committed: committed?,
          blockers: blockers,
          warnings: warnings,
          required_adapters: required_adapters,
          provided_adapters: provided_adapters.map(&:dup),
          would_apply_count: would_apply.length,
          skipped_count: skipped.length,
          metadata: metadata.dup
        }
      end

      private

      def blockers
        [].tap do |items|
          items << blocker(:dry_run_missing, "Activation commit readiness requires dry-run evidence.", dry_run_payload) unless
            dry_run?
          items << blocker(:dry_run_committed, "Activation commit readiness cannot consume committed evidence.", dry_run_payload) if
            committed?
          items << blocker(:dry_run_not_executable, "Activation dry-run is not executable.", dry_run_payload) unless
            dry_run_executable?
          refusals.each do |entry|
            items << blocker(:dry_run_refusal, "Activation dry-run has unresolved refusals.", entry)
          end
          missing_adapters.each do |entry|
            items << blocker(:missing_adapter_evidence, "Activation commit readiness requires explicit adapter evidence.", entry)
          end
        end
      end

      def warnings
        dry_run_warnings.map do |entry|
          warning(:dry_run_warning, "Activation dry-run reported a warning.", entry)
        end
      end

      def required_adapters
        [].tap do |items|
          items << adapter_requirement(:application_host_target, :application_host_adapter, :application_owned_operations, would_apply) if
            would_apply.any?
          items << adapter_requirement(:host_evidence_acknowledgement, :host_evidence, :host_owned_evidence, host_owned_skips) if
            host_owned_skips.any?
          items << adapter_requirement(:manual_action_acknowledgement, :manual_action_evidence, :manual_host_action, manual_skips) if
            manual_skips.any?
          items << adapter_requirement(:web_mount_adapter_evidence, :web_or_host_mount_evidence, :web_or_host_owned_mount, mount_skips) if
            mount_skips.any?
        end
      end

      def missing_adapters
        required_adapters.reject { |entry| adapter_provided?(entry) }
      end

      def adapter_provided?(requirement)
        provided_adapters.any? do |adapter|
          comparable(value(adapter, :name)) == comparable(value(requirement, :name)) ||
            comparable(value(adapter, :kind)) == comparable(value(requirement, :kind))
        end
      end

      def adapter_requirement(name, kind, reason, operations)
        {
          name: name,
          kind: kind,
          reason: reason,
          operation_count: operations.length,
          operations: operations.map(&:dup)
        }
      end

      def dry_run?
        value(dry_run_payload, :dry_run) == true
      end

      def committed?
        value(dry_run_payload, :committed) == true
      end

      def dry_run_executable?
        value(dry_run_payload, :executable) == true
      end

      def would_apply
        Array(value(dry_run_payload, :would_apply)).map { |entry| normalize_hash(entry) }
      end

      def skipped
        Array(value(dry_run_payload, :skipped)).map { |entry| normalize_hash(entry) }
      end

      def refusals
        Array(value(dry_run_payload, :refusals)).map { |entry| normalize_hash(entry) }
      end

      def dry_run_warnings
        Array(value(dry_run_payload, :warnings)).map { |entry| normalize_hash(entry) }
      end

      def host_owned_skips
        skipped.select { |entry| value(entry, :reason).to_s == "host_owned_evidence" }
      end

      def manual_skips
        skipped.select { |entry| value(entry, :reason).to_s == "manual_host_action" }
      end

      def mount_skips
        skipped.select { |entry| value(entry, :reason).to_s == "web_or_host_owned_mount" }
      end

      def payload_from(source)
        payload = source.respond_to?(:to_h) ? source.to_h : source
        normalize_hash(payload)
      end

      def normalize_adapter(entry)
        return { name: entry } unless entry.respond_to?(:to_h)

        normalize_hash(entry)
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

      def blocker(code, message, entry)
        {
          code: code,
          message: message,
          entry: entry
        }
      end

      def warning(code, message, entry)
        {
          code: code,
          message: message,
          entry: entry
        }
      end
    end
  end
end
