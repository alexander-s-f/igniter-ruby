# frozen_string_literal: true

require "find"

module Igniter
  module Application
    class ApplicationTransferInventory
      attr_reader :blueprints, :surface_metadata, :enumerate_files,
                  :capsule_inventories, :metadata

      def self.build(capsules:, surface_metadata: [], enumerate_files: true, metadata: {})
        blueprints = capsules.map { |entry| entry.respond_to?(:to_blueprint) ? entry.to_blueprint : entry }
        new(
          blueprints: blueprints,
          surface_metadata: surface_metadata,
          enumerate_files: enumerate_files,
          metadata: metadata
        )
      end

      def initialize(blueprints:, surface_metadata: [], enumerate_files: true, metadata: {})
        @blueprints = Array(blueprints).freeze
        @surface_metadata = Array(surface_metadata).map { |entry| normalize_hash(entry) }.freeze
        @enumerate_files = enumerate_files ? true : false
        @metadata = metadata.dup.freeze
        @capsule_inventories = @blueprints.map { |blueprint| inventory_for(blueprint) }.freeze
        freeze
      end

      def ready?
        capsule_inventories.all? { |entry| entry.fetch(:missing_expected_paths).empty? && entry.fetch(:skipped_paths).empty? }
      end

      def to_h
        entries = capsule_inventories
        {
          ready: ready?,
          capsule_count: entries.length,
          capsules: entries,
          expected_path_count: entries.sum { |entry| entry.fetch(:expected_count) },
          existing_path_count: entries.sum { |entry| entry.fetch(:existing_count) },
          missing_path_count: entries.sum { |entry| entry.fetch(:missing_count) },
          skipped_path_count: entries.sum { |entry| entry.fetch(:skipped_count) },
          files_enumerated: enumerate_files,
          file_count: enumerate_files ? entries.sum { |entry| entry.fetch(:file_count) } : :not_enumerated,
          surfaces: surface_metadata.map(&:dup),
          metadata: metadata.dup
        }
      end

      private

      def inventory_for(blueprint)
        plan = blueprint.structure_plan(mode: :sparse)
        entries = plan.entries
        expected_paths = entries.map { |entry| expected_path_for(entry) }
        skipped_paths = expected_paths.reject { |entry| path_inside_root?(entry.fetch(:absolute_path), blueprint.root) }
        present_paths = expected_paths.select { |entry| entry.fetch(:status) == :present }
        missing_paths = expected_paths.select { |entry| entry.fetch(:status) == :missing }
        files = enumerate_files ? files_for(blueprint.root, entries) : :not_enumerated

        {
          name: blueprint.name,
          root: blueprint.root,
          layout_profile: blueprint.layout_profile,
          active_groups: blueprint.active_groups,
          expected_paths: expected_paths,
          existing_paths: present_paths,
          missing_expected_paths: missing_paths,
          skipped_paths: skipped_paths,
          expected_count: expected_paths.length,
          existing_count: present_paths.length,
          missing_count: missing_paths.length,
          skipped_count: skipped_paths.length,
          files_enumerated: enumerate_files,
          files: files,
          file_count: enumerate_files ? files.length : :not_enumerated,
          agents: blueprint.agents.map(&:dup),
          surfaces: surfaces_for(blueprint)
        }
      end

      def expected_path_for(entry)
        {
          group: entry.group,
          path: entry.path,
          absolute_path: entry.absolute_path,
          kind: entry.kind,
          status: entry.status
        }
      end

      def files_for(root, entries)
        files = entries.each_with_object([]) do |entry, memo|
          next unless entry.present?
          next unless path_inside_root?(entry.absolute_path, root)

          if entry.kind == :file
            memo << file_entry(root, entry, entry.absolute_path) if File.file?(entry.absolute_path)
          elsif File.directory?(entry.absolute_path)
            collect_directory_files(root, entry, memo)
          end
        end

        files.sort_by { |entry| [entry.fetch(:group).to_s, entry.fetch(:relative_path)] }
      end

      def collect_directory_files(root, entry, memo)
        Find.find(entry.absolute_path) do |path|
          next if path == entry.absolute_path

          if File.symlink?(path)
            Find.prune if File.directory?(path)
            next
          end

          next unless File.file?(path)
          next unless path_inside_root?(path, root)

          memo << file_entry(root, entry, path)
        end
      end

      def file_entry(root, entry, path)
        {
          group: entry.group,
          path: path.sub("#{entry.absolute_path}#{File::SEPARATOR}", ""),
          relative_path: path.sub("#{root}#{File::SEPARATOR}", ""),
          absolute_path: path,
          bytes: File.size(path)
        }
      end

      def surfaces_for(blueprint)
        surface_metadata.select do |entry|
          name = entry[:name] || entry["name"]
          name && blueprint.web_surfaces.include?(name.to_sym)
        end.map(&:dup)
      end

      def path_inside_root?(path, root)
        absolute_path = File.expand_path(path.to_s)
        absolute_root = File.expand_path(root.to_s)
        absolute_path == absolute_root || absolute_path.start_with?("#{absolute_root}#{File::SEPARATOR}")
      end

      def normalize_hash(value)
        source = value.respond_to?(:to_h) ? value.to_h : value
        source.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end
    end
  end
end
