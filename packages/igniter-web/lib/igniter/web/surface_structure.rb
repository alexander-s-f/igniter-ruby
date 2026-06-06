# frozen_string_literal: true

module Igniter
  module Web
    class SurfaceStructure
      GROUPS = %i[screens pages components projections webhooks assets].freeze
      DEFAULT_PATHS = GROUPS.to_h { |group| [group, group.to_s] }.freeze

      attr_reader :web_root, :layout_profile, :groups, :paths, :metadata

      def self.for(blueprint, groups: GROUPS, paths: {}, metadata: {})
        new(
          web_root: blueprint.layout.path(:web),
          layout_profile: blueprint.layout_profile,
          groups: groups,
          paths: paths,
          metadata: metadata.merge(application: blueprint.name)
        )
      end

      def initialize(web_root:, layout_profile: nil, groups: GROUPS, paths: {}, metadata: {})
        @web_root = web_root.to_s
        @layout_profile = layout_profile&.to_sym
        @groups = Array(groups).map(&:to_sym).freeze
        @paths = DEFAULT_PATHS.merge(symbolize_hash(paths)).slice(*@groups).freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def path(group)
        File.join(web_root, paths.fetch(group.to_sym))
      end

      def absolute_path(root, group)
        File.expand_path(path(group), root.to_s)
      end

      def to_h
        {
          web_root: web_root,
          layout_profile: layout_profile,
          groups: groups.dup,
          paths: groups.to_h { |group| [group, path(group)] },
          metadata: metadata.dup
        }
      end

      private

      def symbolize_hash(value)
        value.each_with_object({}) do |(key, entry), memo|
          memo[key.to_sym] = Array(entry).first.to_s
        end
      end
    end
  end
end
