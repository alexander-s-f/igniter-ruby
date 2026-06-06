# frozen_string_literal: true

require "fileutils"
require "json"

module Igniter
  module Application
    class ApplicationTransferBundleArtifactResult
      attr_reader :written, :artifact_path, :included_file_count,
                  :metadata_entry, :refusals, :metadata

      def initialize(written:, artifact_path:, included_file_count:, metadata_entry:, refusals:, metadata: {})
        @written = written == true
        @artifact_path = artifact_path.to_s.freeze
        @included_file_count = included_file_count
        @metadata_entry = metadata_entry
        @refusals = Array(refusals).map(&:dup).freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def written?
        written
      end

      def to_h
        {
          written: written,
          artifact_path: artifact_path,
          included_file_count: included_file_count,
          metadata_entry: metadata_entry,
          refusals: refusals.map(&:dup),
          metadata: metadata.dup
        }
      end
    end

    class ApplicationTransferBundleArtifact
      METADATA_ENTRY = "igniter-transfer-bundle.json"
      FILES_ROOT = "files"

      attr_reader :plan, :output, :allow_not_ready, :create_parent, :metadata

      def self.write(plan, output:, allow_not_ready: false, create_parent: false, metadata: {})
        new(
          plan: plan,
          output: output,
          allow_not_ready: allow_not_ready,
          create_parent: create_parent,
          metadata: metadata
        ).write
      end

      def initialize(plan:, output:, allow_not_ready: false, create_parent: false, metadata: {})
        @plan = plan
        @output = File.expand_path(output.to_s)
        @allow_not_ready = allow_not_ready == true
        @create_parent = create_parent == true
        @metadata = metadata.dup.freeze
        freeze
      end

      def write
        payload = plan_payload
        refusals = refusal_reasons(payload)
        return result(payload: payload, refusals: refusals, written: false) unless refusals.empty?

        FileUtils.mkdir_p(File.dirname(output)) if create_parent
        FileUtils.mkdir_p(File.join(output, FILES_ROOT))
        write_included_files(payload)
        write_metadata(payload)

        result(payload: payload, refusals: [], written: true)
      end

      private

      def plan_payload
        source = plan.respond_to?(:to_h) ? plan.to_h : plan
        source.to_h
      end

      def refusal_reasons(payload)
        [].tap do |items|
          items << refusal(:bundle_not_allowed, "Bundle plan is not allowed by readiness/policy.") if
            !payload.fetch(:bundle_allowed) && !allow_not_ready
          items << refusal(:output_exists, "Output path already exists.") if File.exist?(output)
          items << refusal(:parent_missing, "Output parent directory does not exist.") unless
            create_parent || File.directory?(File.dirname(output))
          items.concat(entry_refusals(payload))
        end
      end

      def entry_refusals(payload)
        payload.fetch(:included_files, []).each_with_object([]) do |entry, items|
          items << refusal(:unsafe_entry_path, "Included file path is not safe.", entry: entry) unless safe_entry?(entry)
          items << refusal(:missing_source, "Included file source does not exist.", entry: entry) unless
            File.file?(entry.fetch(:absolute_path, ""))
        end
      end

      def write_included_files(payload)
        payload.fetch(:included_files, []).each do |entry|
          destination = File.join(output, FILES_ROOT, entry.fetch(:capsule).to_s, entry.fetch(:relative_path))
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.cp(entry.fetch(:absolute_path), destination)
        end
      end

      def write_metadata(payload)
        File.write(
          File.join(output, METADATA_ENTRY),
          JSON.pretty_generate(metadata_payload(payload)) << "\n"
        )
      end

      def metadata_payload(payload)
        {
          kind: :igniter_transfer_bundle,
          subject: payload.fetch(:subject),
          bundle_allowed: payload.fetch(:bundle_allowed),
          included_file_count: payload.fetch(:included_file_count),
          metadata_entry: METADATA_ENTRY,
          files_root: FILES_ROOT,
          plan: payload,
          metadata: metadata.dup
        }
      end

      def result(payload:, refusals:, written:)
        ApplicationTransferBundleArtifactResult.new(
          written: written,
          artifact_path: output,
          included_file_count: written ? payload.fetch(:included_file_count) : 0,
          metadata_entry: written ? METADATA_ENTRY : nil,
          refusals: refusals,
          metadata: metadata
        )
      end

      def safe_entry?(entry)
        relative_path = entry.fetch(:relative_path, "").to_s
        capsule = entry.fetch(:capsule, "").to_s
        return false if relative_path.empty? || capsule.empty?
        return false if relative_path.start_with?("/", "\\")
        return false if capsule.start_with?("/", "\\")

        !relative_path.split(%r{[\\/]}).include?("..") && !capsule.split(%r{[\\/]}).include?("..")
      end

      def refusal(code, message, entry: nil)
        {
          code: code,
          message: message,
          entry: entry
        }.compact
      end
    end
  end
end
