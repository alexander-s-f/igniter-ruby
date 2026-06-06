# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationTransferApplyPlan
      attr_reader :intake_payload, :metadata, :operations

      def self.build(intake_plan, metadata: {})
        new(intake_plan: intake_plan, metadata: metadata)
      end

      def initialize(intake_plan:, metadata: {})
        @intake_payload = payload_from(intake_plan)
        @metadata = metadata.dup.freeze
        @operations = build_operations.freeze
        freeze
      end

      def executable?
        intake_ready? && blockers.empty?
      end

      def to_h
        {
          executable: executable?,
          artifact_path: artifact_path,
          destination_root: destination_root,
          operations: operations,
          operation_count: operations.length,
          blockers: blockers,
          warnings: warnings,
          agent_capabilities: agent_capabilities,
          surface_count: surface_count,
          metadata: metadata.dup
        }
      end

      private

      def payload_from(source)
        payload = source.respond_to?(:to_h) ? source.to_h : source
        payload.to_h
      end

      def build_operations
        directory_operations + file_operations + host_wiring_operations
      end

      def directory_operations
        directories = planned_files.each_with_object({}) do |entry, by_path|
          destination = value(entry, :destination_relative_path)
          next if destination.to_s.empty?

          directory = File.dirname(destination.to_s)
          next if directory == "."

          by_path[directory] ||= []
          by_path[directory] << entry
        end

        directories.keys.sort_by { |path| [path.split(File::SEPARATOR).length, path] }.map do |directory|
          operation(
            type: :ensure_directory,
            status: executable? ? :planned : :blocked,
            source: nil,
            destination: directory,
            metadata: {
              reason: :file_parent,
              file_count: directories.fetch(directory).length
            }
          )
        end
      end

      def file_operations
        planned_files.map do |entry|
          operation(
            type: :copy_file,
            status: copy_status(entry),
            source: value(entry, :artifact_path),
            destination: value(entry, :destination_relative_path),
            metadata: {
              capsule: value(entry, :capsule),
              bytes: value(entry, :bytes),
              intake_status: value(entry, :status),
              safe: value(entry, :safe)
            }
          )
        end
      end

      def host_wiring_operations
        required_host_wiring.map do |entry|
          operation(
            type: :manual_host_wiring,
            status: :review_required,
            source: :intake_required_host_wiring,
            destination: :host,
            metadata: { entry: entry.dup }
          )
        end
      end

      def copy_status(entry)
        return :blocked unless executable?
        return :blocked unless value(entry, :safe)

        status = value(entry, :status)
        return :blocked unless status && status.to_sym == :planned

        :planned
      end

      def operation(type:, status:, source:, destination:, metadata:)
        {
          type: type,
          status: status,
          source: source,
          destination: destination,
          metadata: metadata
        }
      end

      def artifact_path
        value(intake_payload, :artifact_path)
      end

      def destination_root
        value(intake_payload, :destination_root)
      end

      def intake_ready?
        value(intake_payload, :ready) == true
      end

      def planned_files
        Array(value(intake_payload, :planned_files))
      end

      def blockers
        Array(value(intake_payload, :blockers)).map(&:dup)
      end

      def warnings
        Array(value(intake_payload, :warnings)).map(&:dup)
      end

      def agent_capabilities
        Array(value(intake_payload, :agent_capabilities)).map(&:dup)
      end

      def required_host_wiring
        Array(value(intake_payload, :required_host_wiring)).map(&:dup)
      end

      def surface_count
        value(intake_payload, :surface_count) || 0
      end

      def value(hash, key)
        return hash[key] if hash.key?(key)

        hash[key.to_s]
      end
    end
  end
end
