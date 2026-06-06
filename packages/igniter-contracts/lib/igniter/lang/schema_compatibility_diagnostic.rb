# frozen_string_literal: true

module Igniter
  module Lang
    class SchemaCompatibilityDiagnostic
      SEMANTICS = {
        report_only: true,
        runtime_enforced: false,
        migration_execution_authorized: false,
        ledger_core: false
      }.freeze

      REQUIRED_EVIDENCE_LINKS = %i[
        compatibility_report_ref
        semantic_image_ref
        loaded_schema_descriptor_ref
      ].freeze

      REQUIRED_MIGRATION_PROFILE_KEYS = %i[
        migration_receipt_ref
        replaces_image_id
        replacement_semantic_image_ref
        replacement_schema_fingerprint
        loaded_schema_fingerprint
        migration_chain
        replacement_image_lifecycle
        migration_receipt_lifecycle
        packet_links
        post_migration_report_ref
        post_migration_schema_decision
        post_migration_compatibility_decision
      ].freeze

      REQUIRED_PACKET_LINKS = %i[
        replaces
        caused_by
        produced_by
        produced_in
        has_supersedes
      ].freeze

      DECISIONS = %i[trusted provisional migrating blocked].freeze

      attr_reader :diagnostic_id,
                  :contract_ref,
                  :old_schema_version,
                  :new_schema_version,
                  :old_schema_fingerprint,
                  :new_schema_fingerprint,
                  :schema_check_outcome,
                  :migration_available,
                  :compatibility_decision,
                  :evidence_links,
                  :migration_ref,
                  :migration_profile,
                  :profile_cases,
                  :metadata

      def initialize(
        diagnostic_id:,
        contract_ref:,
        old_schema_version:,
        new_schema_version:,
        old_schema_fingerprint:,
        new_schema_fingerprint:,
        schema_check_outcome:,
        migration_available:,
        compatibility_decision:,
        evidence_links:,
        migration_ref: nil,
        migration_profile: nil,
        metadata: {}
      )
        @diagnostic_id = require_value(:diagnostic_id, diagnostic_id)
        @contract_ref = require_value(:contract_ref, contract_ref)
        @old_schema_version = require_value(:old_schema_version, old_schema_version)
        @new_schema_version = require_value(:new_schema_version, new_schema_version)
        @old_schema_fingerprint = require_value(:old_schema_fingerprint, old_schema_fingerprint)
        @new_schema_fingerprint = require_value(:new_schema_fingerprint, new_schema_fingerprint)
        @schema_check_outcome = normalize_decision(:schema_check_outcome, schema_check_outcome)
        @migration_available = normalize_boolean(:migration_available, migration_available)
        @compatibility_decision = normalize_decision(:compatibility_decision, compatibility_decision)
        @evidence_links = normalize_evidence_links(evidence_links)
        @migration_ref = migration_ref
        @migration_profile = normalize_migration_profile(migration_profile)
        validate_migration_evidence!
        @profile_cases = build_profile_cases.freeze
        @metadata = deep_freeze(normalize_hash(metadata, :metadata))
        freeze
      end

      def report_only?
        true
      end

      def runtime_enforced?
        false
      end

      def status
        return :blocked if blocked?
        return :migrating if schema_check_outcome == :migrating || compatibility_decision == :migrating
        return :provisional if schema_check_outcome == :provisional || compatibility_decision == :provisional

        :trusted
      end

      def blocked?
        schema_check_outcome == :blocked ||
          compatibility_decision == :blocked ||
          profile_cases.any? { |entry| entry.fetch(:status) == :blocked }
      end

      def to_h
        payload = {
          diagnostic_id: diagnostic_id,
          contract_ref: contract_ref,
          old_schema_version: old_schema_version,
          new_schema_version: new_schema_version,
          old_schema_fingerprint: old_schema_fingerprint,
          new_schema_fingerprint: new_schema_fingerprint,
          schema_check_outcome: schema_check_outcome,
          migration_available: migration_available,
          compatibility_decision: compatibility_decision,
          status: status,
          evidence_links: evidence_links,
          profile_cases: profile_cases,
          semantics: SEMANTICS,
          metadata: metadata
        }
        payload[:migration_ref] = migration_ref if migration_ref
        payload[:migration_profile] = migration_profile if migration_profile
        payload
      end

      private

      def require_value(name, value)
        raise ArgumentError, "#{name} is required" if value.nil?

        value
      end

      def normalize_decision(name, value)
        decision = require_value(name, value).to_sym
        return decision if DECISIONS.include?(decision)

        raise ArgumentError, "#{name} must be one of #{DECISIONS.join(", ")}"
      end

      def normalize_boolean(name, value)
        return value if [true, false].include?(value)

        raise ArgumentError, "#{name} must be true or false"
      end

      def normalize_evidence_links(value)
        links = normalize_hash(value, :evidence_links)
        REQUIRED_EVIDENCE_LINKS.each do |key|
          raise ArgumentError, "evidence_links.#{key} is required" if links[key].nil?
        end
        deep_freeze(links)
      end

      def validate_migration_evidence!
        return unless migration_available
        return if migration_ref || evidence_links[:migration_descriptor_ref]

        raise ArgumentError, "migration_available requires migration_ref or evidence_links.migration_descriptor_ref"
      end

      def normalize_migration_profile(value)
        return nil if value.nil?

        profile = normalize_hash(value, :migration_profile)
        REQUIRED_MIGRATION_PROFILE_KEYS.each do |key|
          raise ArgumentError, "migration_profile.#{key} is required" if profile[key].nil?
        end

        profile[:post_migration_schema_decision] =
          normalize_decision(:post_migration_schema_decision, profile[:post_migration_schema_decision])
        profile[:post_migration_compatibility_decision] =
          normalize_decision(:post_migration_compatibility_decision, profile[:post_migration_compatibility_decision])
        profile[:packet_links] = normalize_packet_links(profile[:packet_links])
        deep_freeze(profile)
      end

      def normalize_packet_links(value)
        packet_links = normalize_hash(value, :packet_links)
        REQUIRED_PACKET_LINKS.each do |key|
          raise ArgumentError, "migration_profile.packet_links.#{key} is required" if packet_links[key].nil?
        end
        packet_links
      end

      def build_profile_cases
        return [] unless migration_profile

        [
          profile_case("P-1", "migration_receipt_ref", receipt_ref_present?),
          profile_case("P-2", "replaces_image_id", value_present?(migration_profile[:replaces_image_id])),
          profile_case("P-3", "packet_links.replaces", packet_ref_matches?(:replaces, :replaces_image_id)),
          profile_case("P-4", "packet_links.caused_by", packet_ref_matches?(:caused_by, :migration_receipt_ref)),
          profile_case("P-5", "packet_links.has_supersedes", !migration_profile.dig(:packet_links, :has_supersedes)),
          profile_case("P-6", "replacement_schema_fingerprint", replacement_fingerprint_matches?),
          profile_case("P-7", "post_migration_schema_decision", post_migration_schema_trusted?),
          profile_case("P-8", "post_migration_compatibility_decision", post_migration_compatibility_trusted?),
          profile_case("P-9", "migration_chain", migration_profile[:migration_chain] == []),
          p10_case
        ].map { |entry| deep_freeze(entry) }
      end

      def profile_case(code, field, passed)
        {
          code: code,
          field: field.to_sym,
          status: passed ? :trusted : :blocked
        }
      end

      def p10_case
        passed = !wrong_replacement_fingerprint?
        case_entry = profile_case("P-10", "oof_code", passed || oof_mr3_blocked?)
        case_entry[:status] = :blocked if wrong_replacement_fingerprint?
        case_entry[:oof_code] = "OOF-MR3" if wrong_replacement_fingerprint?
        case_entry
      end

      def receipt_ref_present?
        receipt_ref = migration_profile[:migration_receipt_ref]
        return false unless value_present?(receipt_ref)

        linked_receipt = evidence_links[:migration_receipt_ref]
        linked_receipt.nil? || linked_receipt == receipt_ref
      end

      def packet_ref_matches?(link_key, profile_key)
        migration_profile.dig(:packet_links, link_key) == migration_profile[profile_key]
      end

      def replacement_fingerprint_matches?
        migration_profile[:replacement_schema_fingerprint] == migration_profile[:loaded_schema_fingerprint]
      end

      def wrong_replacement_fingerprint?
        !replacement_fingerprint_matches?
      end

      def post_migration_schema_trusted?
        migration_profile[:post_migration_schema_decision] == :trusted
      end

      def post_migration_compatibility_trusted?
        migration_profile[:post_migration_compatibility_decision] == :trusted
      end

      def oof_mr3_blocked?
        migration_profile[:oof_code] == "OOF-MR3" &&
          migration_profile[:post_migration_schema_decision] == :blocked &&
          compatibility_decision == :blocked &&
          schema_check_outcome == :blocked
      end

      def value_present?(value)
        !value.nil? && value != ""
      end

      def normalize_hash(value, name)
        raise ArgumentError, "#{name} must be a hash" unless value.respond_to?(:to_h)

        value.to_h.each_with_object({}) do |(key, entry), hash|
          normalized_key = key.respond_to?(:to_sym) ? key.to_sym : key
          hash[normalized_key] = normalize_value(entry)
        end
      end

      def normalize_value(value)
        case value
        when Hash
          normalize_hash(value, :value)
        when Array
          value.map { |entry| normalize_value(entry) }
        else
          value
        end
      end

      def deep_freeze(value)
        case value
        when Array
          value.map { |entry| deep_freeze(entry) }.freeze
        when Hash
          value.transform_values { |entry| deep_freeze(entry) }.freeze
        else
          value.freeze
        end
      end
    end
  end
end
