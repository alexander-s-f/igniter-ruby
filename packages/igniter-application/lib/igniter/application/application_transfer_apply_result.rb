# frozen_string_literal: true

require "fileutils"
require "set"

module Igniter
  module Application
    class ApplicationTransferApplyResult
      attr_reader :plan_payload, :committed, :metadata, :applied, :skipped, :refusals

      def self.apply(apply_plan, commit: false, metadata: {})
        new(apply_plan: apply_plan, commit: commit, metadata: metadata)
      end

      def initialize(apply_plan:, commit: false, metadata: {})
        @plan_payload = payload_from(apply_plan)
        @committed = commit == true
        @metadata = metadata.dup.freeze
        @applied = []
        @skipped = []
        @refusals = []
        execute
        @applied.freeze
        @skipped.freeze
        @refusals.freeze
        freeze
      end

      def executable?
        value(plan_payload, :executable) == true
      end

      def to_h
        {
          committed: committed,
          executable: executable?,
          applied: applied.map(&:dup),
          skipped: skipped.map(&:dup),
          refusals: refusals.map(&:dup),
          operation_count: operations.length,
          artifact_path: artifact_path,
          destination_root: destination_root,
          surface_count: surface_count,
          metadata: metadata.dup
        }
      end

      private

      def execute
        return refuse_non_executable_plan unless executable?
        return refuse_commit_preflight if committed && !commit_refusals.empty?

        operations.each { |operation| execute_operation(operation) }
      end

      def refuse_non_executable_plan
        refusals << refusal(
          :plan_not_executable,
          "Transfer apply plan is not executable.",
          entry: { blockers: blockers }
        )
        operations.each do |operation|
          skipped << operation_result(operation, :skipped, reason: :plan_not_executable)
        end
      end

      def execute_operation(operation)
        case operation_type(operation)
        when :ensure_directory
          execute_directory_operation(operation)
        when :copy_file
          execute_copy_operation(operation)
        when :manual_host_wiring
          skipped << operation_result(operation, :skipped, reason: :manual_host_wiring_review_only)
        else
          refusals << refusal(:unsupported_operation, "Transfer apply operation type is not supported.", entry: operation)
        end
      end

      def execute_directory_operation(operation)
        destination = destination_path(operation)
        return unless destination

        if File.exist?(destination) && !File.directory?(destination)
          refusals << refusal(:destination_not_directory, "Destination path exists and is not a directory.", entry: operation)
          return
        end

        FileUtils.mkdir_p(destination) if committed && !File.directory?(destination)
        applied << operation_result(operation, committed ? :applied : :dry_run)
      end

      def execute_copy_operation(operation)
        source = source_path(operation)
        destination = destination_path(operation)
        return unless source && destination

        unless File.file?(source)
          refusals << refusal(:missing_source, "Reviewed artifact source file is missing.", entry: operation)
          return
        end
        if File.exist?(destination)
          refusals << refusal(:destination_exists, "Destination file already exists.", entry: operation)
          return
        end
        if committed && !File.directory?(File.dirname(destination))
          refusals << refusal(:destination_parent_missing, "Destination parent directory is missing.", entry: operation)
          return
        end

        FileUtils.cp(source, destination) if committed
        applied << operation_result(operation, committed ? :applied : :dry_run)
      end

      def refuse_commit_preflight
        refusals.concat(commit_refusals)
        operations.each do |operation|
          reason = operation_type(operation) == :manual_host_wiring ? :manual_host_wiring_review_only : :refusals_present
          skipped << operation_result(operation, :skipped, reason: reason)
        end
      end

      def commit_refusals
        @commit_refusals ||= (root_refusals + operations.flat_map { |operation| operation_refusals(operation) }).freeze
      end

      def root_refusals
        [].tap do |items|
          items << refusal(:missing_artifact_root, "Transfer apply plan artifact path is missing.", entry: plan_payload) unless
            artifact_root
          items << refusal(:missing_destination_root, "Transfer apply plan destination root is missing.", entry: plan_payload) unless
            destination_root_path
        end
      end

      def operation_refusals(operation)
        return [] unless artifact_root && destination_root_path

        case operation_type(operation)
        when :ensure_directory
          directory_refusals(operation)
        when :copy_file
          copy_refusals(operation)
        when :manual_host_wiring
          []
        else
          [refusal(:unsupported_operation, "Transfer apply operation type is not supported.", entry: operation)]
        end
      end

      def directory_refusals(operation)
        destination = reviewed_destination_path(operation)
        return [refusal(:unsafe_destination_path, "Reviewed destination path is unsafe.", entry: operation)] unless destination
        return [] unless File.exist?(destination) && !File.directory?(destination)

        [refusal(:destination_not_directory, "Destination path exists and is not a directory.", entry: operation)]
      end

      def copy_refusals(operation)
        source = reviewed_source_path(operation)
        destination = reviewed_destination_path(operation)
        [].tap do |items|
          items << refusal(:unsafe_source_path, "Reviewed source path is unsafe.", entry: operation) unless source
          items << refusal(:unsafe_destination_path, "Reviewed destination path is unsafe.", entry: operation) unless destination
          next unless source && destination

          items << refusal(:missing_source, "Reviewed artifact source file is missing.", entry: operation) unless
            File.file?(source)
          items << refusal(:destination_exists, "Destination file already exists.", entry: operation) if
            File.exist?(destination)
          items << refusal(:destination_parent_missing, "Destination parent directory is missing.", entry: operation) unless
            parent_available_for_commit?(File.dirname(destination))
        end
      end

      def source_path(operation)
        path = reviewed_source_path(operation)
        return path if path

        unsafe_source(operation)
      end

      def destination_path(operation)
        path = reviewed_destination_path(operation)
        return path if path

        unsafe_destination(operation)
      end

      def reviewed_source_path(operation)
        relative = value(operation, :source)
        root = artifact_root
        return nil unless root
        return nil if relative.nil? || !safe_relative_path?(relative)

        path = File.expand_path(relative.to_s, root)
        inside_root?(path, root) ? path : nil
      end

      def reviewed_destination_path(operation)
        relative = value(operation, :destination)
        root = destination_root_path
        return nil unless root
        return nil unless safe_relative_path?(relative)

        path = File.expand_path(relative.to_s, root)
        inside_root?(path, root) ? path : nil
      end

      def parent_available_for_commit?(path)
        File.directory?(path) || reviewed_directory_paths.include?(path)
      end

      def reviewed_directory_paths
        @reviewed_directory_paths ||= operations.filter_map do |operation|
          next unless operation_type(operation) == :ensure_directory

          reviewed_destination_path(operation)
        end.to_set.freeze
      end

      def unsafe_source(operation)
        refusals << refusal(:unsafe_source_path, "Reviewed source path is unsafe.", entry: operation)
        nil
      end

      def unsafe_destination(operation)
        refusals << refusal(:unsafe_destination_path, "Reviewed destination path is unsafe.", entry: operation)
        nil
      end

      def operation_result(operation, status, reason: nil)
        {
          type: operation_type(operation),
          status: status,
          source: value(operation, :source),
          destination: value(operation, :destination),
          metadata: operation_metadata(operation),
          reason: reason
        }.compact
      end

      def operation_type(operation)
        type = value(operation, :type)
        type.respond_to?(:to_sym) ? type.to_sym : type
      end

      def operation_metadata(operation)
        metadata = value(operation, :metadata)
        metadata.respond_to?(:dup) ? metadata.dup : metadata
      end

      def payload_from(source)
        payload = source.respond_to?(:to_h) ? source.to_h : source
        payload.to_h
      end

      def operations
        Array(value(plan_payload, :operations))
      end

      def blockers
        Array(value(plan_payload, :blockers))
      end

      def artifact_path
        value(plan_payload, :artifact_path).to_s
      end

      def destination_root
        value(plan_payload, :destination_root).to_s
      end

      def artifact_root
        @artifact_root ||= expanded_root(value(plan_payload, :artifact_path))
      end

      def destination_root_path
        @destination_root_path ||= expanded_root(value(plan_payload, :destination_root))
      end

      def surface_count
        value(plan_payload, :surface_count) || 0
      end

      def safe_relative_path?(value)
        text = value.to_s
        return false if text.empty?
        return false if text.start_with?("/", "\\")

        !text.split(%r{[\\/]}).include?("..")
      end

      def inside_root?(path, root)
        path == root || path.start_with?("#{root}#{File::SEPARATOR}")
      end

      def expanded_root(value)
        text = value.to_s
        return nil if text.empty?

        File.expand_path(text)
      end

      def value(hash, key)
        return hash[key] if hash.key?(key)

        hash[key.to_s]
      end

      def refusal(code, message, entry:)
        {
          code: code,
          message: message,
          entry: entry
        }
      end
    end
  end
end
