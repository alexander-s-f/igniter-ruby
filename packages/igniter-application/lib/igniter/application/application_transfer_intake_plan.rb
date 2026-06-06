# frozen_string_literal: true

require "json"

module Igniter
  module Application
    class ApplicationTransferIntakePlan
      METADATA_ENTRY = ApplicationTransferBundleArtifact::METADATA_ENTRY
      FILES_ROOT = ApplicationTransferBundleArtifact::FILES_ROOT

      attr_reader :verification, :destination_root, :metadata, :artifact_path,
                  :verification_payload, :bundle_manifest, :planned_files

      def self.build(verification_or_path, destination_root:, metadata: {})
        verification = verification_or_path.respond_to?(:to_h) ? verification_or_path : ApplicationTransferBundleVerification.verify(verification_or_path)
        new(verification: verification, destination_root: destination_root, metadata: metadata)
      end

      def initialize(verification:, destination_root:, metadata: {})
        @verification = verification
        @verification_payload = verification.to_h
        @artifact_path = verification_payload.fetch(:artifact_path)
        @destination_root = File.expand_path(destination_root.to_s)
        @metadata = metadata.dup.freeze
        @bundle_manifest = read_bundle_manifest
        @planned_files = included_files.filter_map { |entry| planned_file(entry) }.freeze
        freeze
      end

      def ready?
        verification_payload.fetch(:valid) && conflicts.empty? && blockers.empty?
      end

      def to_h
        {
          ready: ready?,
          destination_root: destination_root,
          artifact_path: artifact_path,
          verification_valid: verification_payload.fetch(:valid),
          planned_files: planned_files,
          conflicts: conflicts,
          blockers: blockers,
          warnings: warnings,
          required_host_wiring: required_host_wiring,
          agent_capabilities: agent_capabilities,
          surface_count: surfaces.length,
          metadata: metadata.dup
        }
      end

      private

      def read_bundle_manifest
        path = File.join(artifact_path, METADATA_ENTRY)
        return {} unless File.file?(path)

        JSON.parse(File.read(path), symbolize_names: true)
      rescue JSON::ParserError
        {}
      end

      def bundle_plan
        bundle_manifest.fetch(:plan, {})
      end

      def included_files
        Array(bundle_plan.fetch(:included_files, []))
      end

      def planned_file(entry)
        capsule = entry[:capsule] || entry["capsule"]
        relative_path = entry[:relative_path] || entry["relative_path"]
        return unsafe_planned_file(entry) unless safe_component?(capsule) && safe_component?(relative_path)

        capsule = capsule.to_sym
        artifact_relative_path = File.join(FILES_ROOT, capsule.to_s, relative_path.to_s)
        destination_relative_path = File.join(capsule.to_s, relative_path.to_s)
        destination_path = File.expand_path(destination_relative_path, destination_root)
        safe = safe_destination?(destination_path, destination_relative_path)
        exists = safe && File.exist?(destination_path)

        {
          capsule: capsule,
          artifact_path: artifact_relative_path,
          destination_relative_path: destination_relative_path,
          destination_path: destination_path,
          bytes: entry[:bytes],
          status: exists ? :conflict : :planned,
          safe: safe
        }
      end

      def unsafe_planned_file(entry)
        {
          capsule: entry[:capsule] || entry["capsule"],
          artifact_path: nil,
          destination_relative_path: nil,
          destination_path: nil,
          bytes: entry[:bytes] || entry["bytes"],
          status: :unsafe,
          safe: false
        }
      end

      def conflicts
        planned_files.select { |entry| entry.fetch(:status) == :conflict }.map do |entry|
          entry.merge(code: :destination_exists, message: "Destination file already exists.")
        end
      end

      def blockers
        [].tap do |items|
          items << blocker(:verification_invalid, "Bundle verification is not valid.", verification_payload) unless
            verification_payload.fetch(:valid)
          planned_files.reject { |entry| entry.fetch(:safe) }.each do |entry|
            items << blocker(:unsafe_destination_path, "Planned destination path is unsafe.", entry)
          end
          conflicts.each do |entry|
            items << blocker(:destination_conflict, "Destination file already exists.", entry)
          end
          required_host_wiring.each do |entry|
            items << blocker(:required_host_wiring, "Required host wiring remains unresolved.", entry)
          end
        end
      end

      def warnings
        readiness_warnings
      end

      def readiness_warnings
        bundle_plan.fetch(:warnings, []).map(&:dup)
      end

      def required_host_wiring
        manifest = bundle_plan.fetch(:readiness, {}).fetch(:manifest, {})
        manifest.fetch(:suggested_host_wiring, []).map(&:dup)
      end

      def agent_capabilities
        manifest = bundle_plan.fetch(:readiness, {}).fetch(:manifest, {})
        manifest.fetch(:capsules, []).flat_map do |capsule|
          capsule.fetch(:agents, []).map do |agent|
            normalize_agent(agent).merge(capsule: capsule.fetch(:name).to_sym)
          end
        end
      end

      def normalize_agent(agent)
        {
          name: agent.fetch(:name).to_sym,
          ai_provider: agent.fetch(:ai_provider).to_sym,
          model: agent[:model],
          instructions: agent[:instructions],
          tools: Array(agent.fetch(:tools, [])).map(&:to_sym),
          memory: agent[:memory],
          metadata: normalize_hash(agent.fetch(:metadata, {}))
        }.compact
      end

      def normalize_hash(value)
        source = value.respond_to?(:to_h) ? value.to_h : value
        source.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end

      def surfaces
        bundle_plan.fetch(:surfaces, [])
      end

      def safe_destination?(destination_path, destination_relative_path)
        return false if destination_relative_path.empty?
        return false if destination_relative_path.start_with?("/", "\\")
        return false if destination_relative_path.split(%r{[\\/]}).include?("..")

        destination_path == destination_root || destination_path.start_with?("#{destination_root}#{File::SEPARATOR}")
      end

      def safe_component?(value)
        text = value.to_s
        return false if text.empty?
        return false if text.start_with?("/", "\\")

        !text.split(%r{[\\/]}).include?("..")
      end

      def blocker(code, message, entry)
        {
          code: code,
          message: message,
          entry: entry
        }
      end
    end
  end
end
