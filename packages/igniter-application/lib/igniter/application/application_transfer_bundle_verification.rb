# frozen_string_literal: true

require "find"
require "json"

module Igniter
  module Application
    class ApplicationTransferBundleVerification
      METADATA_ENTRY = ApplicationTransferBundleArtifact::METADATA_ENTRY
      FILES_ROOT = ApplicationTransferBundleArtifact::FILES_ROOT

      attr_reader :artifact_path, :manifest, :metadata

      def self.verify(path, metadata: {})
        new(path: path, metadata: metadata)
      end

      def initialize(path:, metadata: {})
        @artifact_path = File.expand_path(path.to_s)
        @metadata = metadata.dup.freeze
        @manifest = read_manifest
        freeze
      end

      def valid?
        malformed_entries.empty? && missing_files.empty? && extra_files.empty?
      end

      def to_h
        {
          valid: valid?,
          artifact_path: artifact_path,
          metadata_entry: METADATA_ENTRY,
          missing_files: missing_files,
          extra_files: extra_files,
          malformed_entries: malformed_entries,
          included_file_count: included_file_count,
          actual_file_count: actual_files.length,
          surface_count: surfaces.length,
          metadata: metadata.dup
        }
      end

      private

      def read_manifest
        path = File.join(artifact_path, METADATA_ENTRY)
        return nil unless File.file?(path)

        JSON.parse(File.read(path), symbolize_names: true)
      rescue JSON::ParserError
        nil
      end

      def plan
        manifest&.fetch(:plan, nil) || {}
      end

      def included_files
        Array(plan.fetch(:included_files, []))
      end

      def included_file_count
        plan.fetch(:included_file_count, included_files.length)
      end

      def surfaces
        Array(plan.fetch(:surfaces, []))
      end

      def expected_files
        included_files.filter_map do |entry|
          next unless well_formed_file_entry?(entry)

          File.join(FILES_ROOT, entry.fetch(:capsule).to_s, entry.fetch(:relative_path).to_s)
        end.sort
      end

      def actual_files
        root = File.join(artifact_path, FILES_ROOT)
        return [] unless File.directory?(root)

        files = []
        Find.find(root) do |path|
          next if path == root

          if File.symlink?(path)
            Find.prune if File.directory?(path)
            next
          end

          next unless File.file?(path)

          files << relative_to_artifact(path)
        end
        files.sort
      end

      def missing_files
        expected_files - actual_files
      end

      def extra_files
        actual_files - expected_files
      end

      def malformed_entries
        entries = []
        entries << malformed(:metadata_missing, "Metadata manifest is missing.") unless File.file?(metadata_path)
        entries << malformed(:metadata_invalid, "Metadata manifest is not valid JSON.") if File.file?(metadata_path) && manifest.nil?
        included_files.each do |entry|
          next if well_formed_file_entry?(entry)

          entries << malformed(:malformed_file_entry, "Included file entry is malformed or unsafe.", entry: entry)
        end
        entries
      end

      def well_formed_file_entry?(entry)
        capsule = entry[:capsule] || entry["capsule"]
        relative_path = entry[:relative_path] || entry["relative_path"]
        safe_component?(capsule) && safe_relative_path?(relative_path)
      end

      def safe_component?(value)
        text = value.to_s
        return false if text.empty?
        return false if text.start_with?("/", "\\")

        !text.split(%r{[\\/]}).include?("..")
      end

      def safe_relative_path?(value)
        safe_component?(value)
      end

      def metadata_path
        File.join(artifact_path, METADATA_ENTRY)
      end

      def relative_to_artifact(path)
        path.sub("#{artifact_path}#{File::SEPARATOR}", "")
      end

      def malformed(code, message, entry: nil)
        {
          code: code,
          message: message,
          entry: entry
        }.compact
      end
    end
  end
end
