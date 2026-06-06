# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationAssemblyPlan
      attr_reader :blueprints, :composition_report, :mount_intents,
                  :surface_metadata, :metadata

      def self.build(capsules:, host_exports: [], host_capabilities: [], mount_intents: [],
                     surface_metadata: [], metadata: {})
        blueprints = capsules.map { |entry| entry.respond_to?(:to_blueprint) ? entry.to_blueprint : entry }
        new(
          blueprints: blueprints,
          composition_report: ApplicationCompositionReport.inspect(
            capsules: blueprints,
            host_exports: host_exports,
            host_capabilities: host_capabilities
          ),
          mount_intents: mount_intents,
          surface_metadata: surface_metadata,
          metadata: metadata
        )
      end

      def initialize(blueprints:, composition_report:, mount_intents: [], surface_metadata: [], metadata: {})
        @blueprints = Array(blueprints).freeze
        @composition_report = composition_report
        @mount_intents = Array(mount_intents).map { |entry| MountIntent.from(entry) }.freeze
        @surface_metadata = Array(surface_metadata).map { |entry| normalize_hash(entry) }.freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def ready?
        composition_report.ready? && unresolved_mount_intents.empty?
      end

      def to_h
        {
          capsules: capsule_names,
          composition: composition_report.to_h,
          composition_ready: composition_report.ready?,
          mount_intents: mount_intents.map(&:to_h),
          unresolved_mount_intents: unresolved_mount_intents,
          surfaces: surface_metadata.map(&:dup),
          ready: ready?,
          metadata: metadata.dup
        }
      end

      def capsule_names
        blueprints.map(&:name)
      end

      def unresolved_mount_intents
        mount_intents.reject { |intent| capsule_names.include?(intent.capsule) }.map(&:to_h)
      end

      private

      def normalize_hash(value)
        source = value.respond_to?(:to_h) ? value.to_h : value
        source.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end
    end
  end
end
