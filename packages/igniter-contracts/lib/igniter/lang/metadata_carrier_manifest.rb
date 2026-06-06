# frozen_string_literal: true

module Igniter
  module Lang
    class MetadataCarrierManifest
      KNOWN_SECTIONS = %i[
        diagnostics
        receipts
        model_validity_reports
        scenario_comparison_reports
        review_receipts
      ].freeze

      CUSTOM_SECTIONS_KEY = :custom_sections

      ENTRY_SEMANTICS = {
        report_only: true,
        runtime_enforced: false,
        raw_ref_export: false
      }.freeze

      attr_reader :sections

      def self.from_metadata(metadata)
        new(sections: build_sections(metadata))
      end

      def initialize(sections: [])
        @sections = sections.map { |entry| deep_freeze(entry) }.freeze
        freeze
      end

      def empty?
        sections.empty?
      end

      def to_h
        {
          sections: sections
        }
      end

      class << self
        private

        def build_sections(metadata)
          metadata_hash = metadata.to_h
          known_sections = KNOWN_SECTIONS.filter_map do |section_name|
            next unless metadata_hash.key?(section_name)

            build_section(section_name, metadata_hash.fetch(section_name), custom: false)
          end

          custom_sections = build_custom_sections(metadata_hash.fetch(CUSTOM_SECTIONS_KEY, {}))
          known_sections + custom_sections
        end

        def build_custom_sections(value)
          return [] if value.nil? || value == {}
          raise ArgumentError, "metadata.custom_sections must be a hash" unless value.is_a?(Hash)

          value.to_h.map do |section_name, entries|
            normalized_name = section_name.respond_to?(:to_sym) ? section_name.to_sym : section_name
            raise ArgumentError, "metadata.custom_sections.#{normalized_name} duplicates a known section" if KNOWN_SECTIONS.include?(normalized_name)

            build_section(normalized_name, entries, custom: true)
          end
        end

        def build_section(section_name, value, custom:)
          entries = normalize_section_entries(section_name, value)
          {
            section_name: section_name,
            count: entries.length,
            profile_names: profile_names(entries),
            custom: custom
          }.merge(ENTRY_SEMANTICS)
        end

        def normalize_section_entries(section_name, value)
          raise ArgumentError, "metadata.#{section_name} must be an array of hashes" unless value.is_a?(Array)

          value.each_with_index.map do |entry, index|
            raise ArgumentError, "metadata.#{section_name}[#{index}] must be a hash" unless entry.respond_to?(:to_h)

            entry.to_h
          end
        end

        def profile_names(entries)
          entries.filter_map do |entry|
            profile = entry[:profile] || entry["profile"] || entry[:profile_name] || entry["profile_name"]
            profile.to_s unless profile.nil?
          end.uniq.freeze
        end
      end

      private

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
