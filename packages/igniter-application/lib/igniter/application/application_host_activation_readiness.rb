# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationHostActivationReadiness
      attr_reader :receipt_payload, :handoff_payload, :host_exports, :host_capabilities,
                  :manual_decisions, :load_paths, :providers, :contracts,
                  :lifecycle, :mount_decisions, :surface_metadata, :metadata

      def self.build(transfer_receipt, handoff_manifest: nil, host_exports: [], host_capabilities: [],
                     manual_actions: [], load_paths: [], providers: [], contracts: [], lifecycle: {},
                     mount_decisions: [], surface_metadata: [], metadata: {})
        new(
          transfer_receipt: transfer_receipt,
          handoff_manifest: handoff_manifest,
          host_exports: host_exports,
          host_capabilities: host_capabilities,
          manual_actions: manual_actions,
          load_paths: load_paths,
          providers: providers,
          contracts: contracts,
          lifecycle: lifecycle,
          mount_decisions: mount_decisions,
          surface_metadata: surface_metadata,
          metadata: metadata
        )
      end

      def initialize(transfer_receipt:, handoff_manifest: nil, host_exports: [], host_capabilities: [],
                     manual_actions: [], load_paths: [], providers: [], contracts: [], lifecycle: {},
                     mount_decisions: [], surface_metadata: [], metadata: {})
        @receipt_payload = payload_from(transfer_receipt)
        @handoff_payload = handoff_manifest ? payload_from(handoff_manifest) : nil
        @host_exports = Array(host_exports).map { |entry| normalize_hash(entry) }.freeze
        @host_capabilities = Array(host_capabilities).map { |entry| normalize_scalar(entry) }.freeze
        @manual_decisions = Array(manual_actions).map { |entry| normalize_hash(entry) }.freeze
        @load_paths = Array(load_paths).map { |entry| normalize_scalar(entry) }.freeze
        @providers = Array(providers).map { |entry| normalize_scalar(entry) }.freeze
        @contracts = Array(contracts).map { |entry| normalize_scalar(entry) }.freeze
        @lifecycle = normalize_hash(lifecycle).freeze
        @mount_decisions = Array(mount_decisions).map { |entry| normalize_hash(entry) }.freeze
        @surface_metadata = Array(surface_metadata).map { |entry| normalize_hash(entry) }.freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def ready?
        blockers.empty?
      end

      def to_h
        {
          ready: ready?,
          blockers: blockers,
          warnings: warnings,
          decisions: decisions,
          manual_actions: required_manual_actions,
          mount_intents: mount_intents,
          surface_count: surface_count,
          metadata: metadata.dup
        }
      end

      private

      def blockers
        [].tap do |items|
          items << blocker(:transfer_receipt_incomplete, "Transfer receipt is not complete.", receipt_payload) unless
            value(receipt_payload, :complete) == true
          required_host_wiring.each do |entry|
            items << blocker(:missing_host_export, "Required host export decision is missing.", entry) unless
              host_export_satisfied?(entry)
            missing_capabilities(entry).each do |capability|
              items << blocker(
                :missing_host_capability,
                "Required host capability decision is missing.",
                entry.merge(capability: capability)
              )
            end
          end
          unresolved_manual_actions.each do |entry|
            items << blocker(:manual_action_unresolved, "Manual host action is not resolved.", entry)
          end
        end
      end

      def warnings
        [].tap do |items|
          items << warning(:handoff_manifest_missing, "Handoff manifest was not supplied.") unless handoff_payload
          items << warning(:load_paths_unconfirmed, "Host load path decision was not supplied.") if load_paths.empty?
          items << warning(:providers_unconfirmed, "Host provider decision was not supplied.") if providers.empty?
          items << warning(:contracts_unconfirmed, "Host contract registration decision was not supplied.") if contracts.empty?
          items << warning(:lifecycle_unconfirmed, "Host lifecycle decision was not supplied.") if lifecycle.empty?
          unconfirmed_mount_intents.each do |entry|
            items << warning(:mount_intent_unconfirmed, "Mount intent remains a host review decision.", entry)
          end
        end
      end

      def decisions
        {
          host_exports: host_exports.map(&:dup),
          host_capabilities: host_capabilities.dup,
          manual_actions: manual_decisions.map(&:dup),
          load_paths: load_paths.dup,
          providers: providers.dup,
          contracts: contracts.dup,
          lifecycle: lifecycle.dup,
          mount_decisions: mount_decisions.map(&:dup)
        }
      end

      def required_host_wiring
        return [] unless handoff_payload

        Array(value(handoff_payload, :suggested_host_wiring)).map { |entry| normalize_hash(entry) }
      end

      def required_manual_actions
        Array(value(receipt_payload, :manual_actions)).map { |entry| normalize_hash(entry) }
      end

      def unresolved_manual_actions
        required_manual_actions.reject { |entry| manual_action_resolved?(entry) }
      end

      def manual_action_resolved?(entry)
        manual_decisions.any? do |decision|
          same_name?(decision, entry) && resolved_status?(value(decision, :status))
        end
      end

      def host_export_satisfied?(entry)
        host_exports.any? do |host_export|
          same_name?(host_export, entry) && compatible_kind?(host_export, entry)
        end
      end

      def missing_capabilities(entry)
        Array(value(entry, :capabilities)).reject do |capability|
          host_capabilities.any? { |host_capability| comparable(host_capability) == comparable(capability) }
        end
      end

      def mount_intents
        return [] unless handoff_payload

        Array(value(handoff_payload, :mount_intents)).map { |entry| normalize_hash(entry) }
      end

      def unconfirmed_mount_intents
        mount_intents.reject do |entry|
          mount_decisions.any? { |decision| same_mount?(decision, entry) && resolved_status?(value(decision, :status)) }
        end
      end

      def surface_count
        supplied_surface_count = surface_metadata.length
        handoff_surface_count = handoff_payload ? Array(value(handoff_payload, :surfaces)).length : 0
        receipt_surface_count = value(receipt_payload, :surface_count).to_i
        [supplied_surface_count, handoff_surface_count, receipt_surface_count].max
      end

      def same_name?(left, right)
        comparable(value(left, :name)) == comparable(value(right, :name))
      end

      def compatible_kind?(left, right)
        expected = value(right, :kind)
        actual = value(left, :kind)
        expected.nil? || actual.nil? || comparable(actual) == comparable(expected)
      end

      def same_mount?(left, right)
        comparable(value(left, :capsule)) == comparable(value(right, :capsule)) &&
          comparable(value(left, :kind)) == comparable(value(right, :kind)) &&
          value(left, :at).to_s == value(right, :at).to_s
      end

      def resolved_status?(status)
        %i[accepted complete completed wired provided ready].include?(status.respond_to?(:to_sym) ? status.to_sym : status)
      end

      def blocker(code, message, entry)
        {
          code: code,
          message: message,
          entry: entry
        }
      end

      def warning(code, message, entry = nil)
        {
          code: code,
          message: message,
          entry: entry
        }.compact
      end

      def payload_from(source)
        payload = source.respond_to?(:to_h) ? source.to_h : source
        payload.to_h
      end

      def normalize_hash(value)
        source = value.respond_to?(:to_h) ? value.to_h : value
        source.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end

      def normalize_scalar(value)
        value
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
