# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationCapsuleReport
      attr_reader :blueprint, :surface_metadata, :metadata

      def self.for_blueprint(blueprint, surface_metadata: [], metadata: {})
        new(blueprint: blueprint, surface_metadata: surface_metadata, metadata: metadata)
      end

      def initialize(blueprint:, surface_metadata: [], metadata: {})
        @blueprint = blueprint
        @surface_metadata = Array(surface_metadata).map { |entry| normalize_hash(entry) }.freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def to_h
        {
          name: blueprint.name,
          root: blueprint.root,
          env: blueprint.env,
          layout_profile: blueprint.layout_profile,
          groups: {
            active: blueprint.active_groups,
            known: blueprint.known_groups
          },
          planned_paths: {
            sparse: planned_paths_for(:sparse),
            complete: planned_paths_for(:complete)
          },
          exports: blueprint.exports.map(&:to_h),
          imports: blueprint.imports.map(&:to_h),
          feature_slices: blueprint.feature_slices.map(&:to_h),
          flow_declarations: blueprint.flow_declarations.map(&:to_h),
          contracts: blueprint.contracts.dup,
          services: blueprint.services.dup,
          interfaces: blueprint.interfaces.dup,
          agents: blueprint.agents.map(&:dup),
          web_surfaces: blueprint.web_surfaces.dup,
          surfaces: surface_metadata.map(&:dup),
          metadata: metadata.dup
        }
      end

      private

      def planned_paths_for(mode)
        blueprint.structure_plan(mode: mode).to_h.fetch(:entries).map do |entry|
          entry.slice(:group, :path, :absolute_path, :kind, :status, :action)
        end
      end

      def normalize_hash(value)
        source = value.respond_to?(:to_h) ? value.to_h : value
        source.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end
    end
  end
end
