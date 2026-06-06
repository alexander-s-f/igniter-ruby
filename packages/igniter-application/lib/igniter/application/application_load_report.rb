# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationLoadReport
      attr_reader :base_dir, :layout, :entries, :metadata

      def self.inspect(base_dir:, layout:, paths:, metadata: {})
        entries = paths.flat_map do |group, group_paths|
          Array(group_paths).map do |path|
            absolute_path = File.expand_path(path.to_s, base_dir.to_s)
            ApplicationLoadPath.new(
              group: group,
              path: path,
              absolute_path: absolute_path,
              kind: path_kind(absolute_path),
              status: File.exist?(absolute_path) ? :present : :missing,
              metadata: {
                layout_path: layout.paths[group.to_sym]
              }.compact
            )
          end
        end

        new(base_dir: base_dir, layout: layout, entries: entries, metadata: metadata)
      end

      def self.path_kind(absolute_path)
        return :directory if File.directory?(absolute_path)
        return :file if File.file?(absolute_path)

        :missing
      end

      def initialize(base_dir:, layout:, entries:, metadata: {})
        @base_dir = File.expand_path(base_dir.to_s)
        @layout = layout
        @entries = Array(entries).freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def present_entries
        entries.select(&:present?)
      end

      def missing_entries
        entries.select(&:missing?)
      end

      def present_groups
        present_entries.map(&:group).uniq.sort
      end

      def missing_groups
        missing_entries.map(&:group).uniq.sort
      end

      def to_h
        {
          base_dir: base_dir,
          layout: layout.to_h,
          entry_count: entries.length,
          present_count: present_entries.length,
          missing_count: missing_entries.length,
          present_groups: present_groups,
          missing_groups: missing_groups,
          entries: entries.map(&:to_h),
          metadata: metadata.dup
        }
      end
    end
  end
end
