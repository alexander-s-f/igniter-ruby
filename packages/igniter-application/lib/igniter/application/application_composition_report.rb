# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationCompositionReport
      attr_reader :blueprints, :host_exports, :host_capabilities, :metadata

      def self.inspect(capsules:, host_exports: [], host_capabilities: [], metadata: {})
        new(
          blueprints: capsules.map { |entry| entry.respond_to?(:to_blueprint) ? entry.to_blueprint : entry },
          host_exports: host_exports,
          host_capabilities: host_capabilities,
          metadata: metadata
        )
      end

      def initialize(blueprints:, host_exports: [], host_capabilities: [], metadata: {})
        @blueprints = Array(blueprints).freeze
        @host_exports = Array(host_exports).map { |entry| normalize_export(entry, capsule: :host, source: :host) }.freeze
        @host_capabilities = Array(host_capabilities).map(&:to_sym).sort.freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def ready?
        unresolved_required_imports.empty?
      end

      def to_h
        {
          capsule_count: blueprints.length,
          capsules: capsules,
          exports: capsule_exports,
          host_exports: host_exports.map(&:dup),
          host_capabilities: host_capabilities.dup,
          imports: capsule_imports,
          satisfied_imports: satisfied_imports,
          host_satisfied_imports: host_satisfied_imports,
          unresolved_required_imports: unresolved_required_imports,
          missing_optional_imports: missing_optional_imports,
          ready: ready?,
          metadata: metadata.dup
        }
      end

      def capsules
        blueprints.map do |blueprint|
          {
            name: blueprint.name,
            root: blueprint.root,
            env: blueprint.env,
            layout_profile: blueprint.layout_profile
          }
        end
      end

      def capsule_exports
        blueprints.flat_map do |blueprint|
          blueprint.exports.map { |entry| normalize_export(entry.to_h, capsule: blueprint.name, source: :capsule) }
        end
      end

      def capsule_imports
        blueprints.flat_map do |blueprint|
          blueprint.imports.map { |entry| normalize_import(entry.to_h, capsule: blueprint.name) }
        end
      end

      def satisfied_imports
        capsule_imports.filter_map do |entry|
          export = matching_capsule_export(entry)
          next unless export

          satisfaction_for(entry, export, satisfied_by: :capsule)
        end
      end

      def host_satisfied_imports
        capsule_imports.filter_map do |entry|
          next if matching_capsule_export(entry)

          export = matching_host_export(entry)
          next unless export

          satisfaction_for(entry, export, satisfied_by: :host)
        end
      end

      def unresolved_required_imports
        capsule_imports.select do |entry|
          !entry.fetch(:optional) && matching_capsule_export(entry).nil? && matching_host_export(entry).nil?
        end.map(&:dup)
      end

      def missing_optional_imports
        capsule_imports.select do |entry|
          entry.fetch(:optional) && matching_capsule_export(entry).nil? && matching_host_export(entry).nil?
        end.map(&:dup)
      end

      private

      def matching_capsule_export(import)
        capsule_exports.find do |export|
          export.fetch(:capsule) != import.fetch(:capsule) &&
            export.fetch(:name) == import.fetch(:name) &&
            export.fetch(:kind) == import.fetch(:kind)
        end
      end

      def matching_host_export(import)
        host_exports.find do |export|
          export.fetch(:name) == import.fetch(:name) && export.fetch(:kind) == import.fetch(:kind)
        end
      end

      def satisfaction_for(import, export, satisfied_by:)
        {
          capsule: import.fetch(:capsule),
          name: import.fetch(:name),
          kind: import.fetch(:kind),
          optional: import.fetch(:optional),
          satisfied_by: satisfied_by,
          provider_capsule: export.fetch(:capsule),
          export: export.dup,
          import: import.dup
        }
      end

      def normalize_export(value, capsule:, source:)
        entry = normalize_hash(value)
        {
          capsule: capsule,
          source: source,
          name: entry.fetch(:name).to_sym,
          kind: entry.fetch(:kind, entry.fetch(:as, :service)).to_sym,
          target: entry[:target],
          metadata: entry.fetch(:metadata, {}).dup
        }
      end

      def normalize_import(value, capsule:)
        entry = normalize_hash(value)
        {
          capsule: capsule,
          name: entry.fetch(:name).to_sym,
          kind: entry.fetch(:kind, :service).to_sym,
          from: entry[:from],
          optional: entry.fetch(:optional, false) == true,
          capabilities: Array(entry.fetch(:capabilities, [])).map(&:to_sym).sort,
          metadata: entry.fetch(:metadata, {}).dup
        }
      end

      def normalize_hash(value)
        source = value.respond_to?(:to_h) ? value.to_h : value
        source.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end
    end
  end
end
