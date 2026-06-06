# frozen_string_literal: true

module Igniter
  module Application
    class FeatureSliceReport
      attr_reader :application_name, :root, :layout_profile, :slices, :metadata

      def initialize(application_name:, root:, layout_profile:, slices: [], metadata: {})
        @application_name = application_name.to_sym
        @root = File.expand_path(root.to_s)
        @layout_profile = layout_profile.to_sym
        @slices = Array(slices).map { |entry| FeatureSlice.from(entry) }.freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def self.for_blueprint(blueprint, metadata: {})
        new(
          application_name: blueprint.name,
          root: blueprint.root,
          layout_profile: blueprint.layout_profile,
          slices: blueprint.feature_slices,
          metadata: metadata
        )
      end

      def empty?
        slices.empty?
      end

      def to_h
        {
          application_name: application_name,
          root: root,
          layout_profile: layout_profile,
          slice_count: slices.length,
          slices: slices.map(&:to_h),
          metadata: metadata.dup
        }
      end
    end
  end
end
