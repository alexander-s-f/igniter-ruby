# frozen_string_literal: true

module Igniter
  module DurableModel
    # Deterministic app-safe export envelope for command-flow evidence profiles.
    class CommandFlowEvidenceExport
      attr_reader :schema_version, :kind, :export_id, :profile_kind, :owner,
                  :view_name, :action, :actor, :status, :meaning_status,
                  :privacy, :generated_at, :content_hash, :canonical_json,
                  :profile, :packets, :links, :diagnostics, :redactions,
                  :metadata, :store_fact_exposed, :value_hash_exposed

      def initialize(export_id:, profile_kind:, owner:, view_name:, status:,
                     meaning_status:, privacy:, generated_at:, content_hash:,
                     canonical_json:, profile:, packets:, links:,
                     diagnostics:, redactions:, action: nil, actor: nil,
                     metadata: {}, schema_version: 1,
                     kind: :command_flow_evidence_export,
                     store_fact_exposed: false, value_hash_exposed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @export_id = export_id
        @profile_kind = token(profile_kind)
        @owner = token(owner)
        @view_name = token(view_name)
        @action = token(action)
        @actor = actor
        @status = token(status)
        @meaning_status = token(meaning_status)
        @privacy = token(privacy)
        @generated_at = generated_at
        @content_hash = content_hash
        @canonical_json = canonical_json
        @profile = normalize_hash(profile).freeze
        @packets = Array(packets).map { |packet| normalize_hash(packet).freeze }.freeze
        @links = Array(links).map { |link| normalize_hash(link).freeze }.freeze
        @diagnostics = Array(diagnostics).map { |diagnostic| normalize_hash(diagnostic).freeze }.freeze
        @redactions = Array(redactions).map { |redaction| normalize_hash(redaction).freeze }.freeze
        @metadata = normalize_hash(metadata).freeze
        @store_fact_exposed = store_fact_exposed ? true : false
        @value_hash_exposed = value_hash_exposed ? true : false
        freeze
      end

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          export_id: export_id,
          profile_kind: profile_kind,
          owner: owner,
          view_name: view_name,
          action: action,
          actor: actor,
          status: status,
          meaning_status: meaning_status,
          privacy: privacy,
          generated_at: generated_at,
          content_hash: content_hash,
          canonical_json: canonical_json,
          profile: profile,
          packets: packets,
          links: links,
          diagnostics: diagnostics,
          redactions: redactions,
          metadata: metadata,
          store_fact_exposed: store_fact_exposed,
          value_hash_exposed: value_hash_exposed
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

      def token(value)
        value.is_a?(String) ? value.to_sym : value
      end
    end
  end
end
