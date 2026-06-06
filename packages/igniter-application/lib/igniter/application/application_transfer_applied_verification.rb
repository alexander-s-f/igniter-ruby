# frozen_string_literal: true

require "set"

module Igniter
  module Application
    class ApplicationTransferAppliedVerification
      attr_reader :result_payload, :plan_payload, :metadata, :verified, :findings

      def self.verify(apply_result, apply_plan: nil, metadata: {})
        new(apply_result: apply_result, apply_plan: apply_plan, metadata: metadata)
      end

      def initialize(apply_result:, apply_plan: nil, metadata: {})
        @result_payload = payload_from(apply_result)
        @plan_payload = apply_plan ? payload_from(apply_plan) : nil
        @metadata = metadata.dup.freeze
        @verified = []
        @findings = []
        verify
        @verified.freeze
        @findings.freeze
        freeze
      end

      def valid?
        committed? && findings.empty? && refusals.empty? && non_review_skipped.empty?
      end

      def to_h
        {
          valid: valid?,
          committed: committed?,
          artifact_path: artifact_path,
          destination_root: destination_root,
          verified: verified.map(&:dup),
          findings: findings.map(&:dup),
          refusals: refusals.map(&:dup),
          skipped: skipped.map(&:dup),
          operation_count: operation_count,
          surface_count: surface_count,
          metadata: metadata.dup
        }
      end

      private

      def verify
        findings << finding(:not_committed, "Transfer apply result was not committed.") unless committed?
        findings << finding(:refusals_present, "Transfer apply result has refusals.", entries: refusals) unless
          refusals.empty?
        non_review_skipped.each do |entry|
          findings << finding(:operation_skipped, "Transfer apply operation was skipped.", entry: entry)
        end

        verify_expected_operations
        report_unexpected_applied_operations
      end

      def verify_expected_operations
        expected_verifiable_operations.each do |operation|
          signature = operation_signature(operation)
          applied = applied_by_signature.fetch(signature, nil)

          unless applied
            findings << finding(:operation_not_applied, "Reviewed operation is not present in applied result.", entry: operation)
            next
          end

          verify_operation(operation, applied)
        end
      end

      def verify_operation(operation, applied)
        case operation_type(operation)
        when :ensure_directory
          verify_directory(operation, applied)
        when :copy_file
          verify_file(operation, applied)
        end
      end

      def verify_directory(operation, applied)
        destination = destination_path(operation)
        unless destination
          findings << finding(:unsafe_destination_path, "Reviewed destination path is unsafe.", entry: operation)
          return
        end

        unless File.directory?(destination)
          findings << finding(:missing_destination_directory, "Reviewed destination directory is missing.", entry: operation)
          return
        end

        verified << verification_entry(operation, applied, :verified)
      end

      def verify_file(operation, applied)
        source = source_path(operation)
        destination = destination_path(operation)
        unless source
          findings << finding(:unsafe_source_path, "Reviewed source path is unsafe.", entry: operation)
          return
        end
        unless destination
          findings << finding(:unsafe_destination_path, "Reviewed destination path is unsafe.", entry: operation)
          return
        end
        unless File.file?(source)
          findings << finding(:missing_source_file, "Reviewed artifact source file is missing.", entry: operation)
          return
        end
        unless File.file?(destination)
          findings << finding(:missing_destination_file, "Reviewed destination file is missing.", entry: operation)
          return
        end

        source_bytes = File.size(source)
        destination_bytes = File.size(destination)
        if source_bytes != destination_bytes
          findings << finding(
            :byte_size_mismatch,
            "Reviewed destination file size does not match artifact source.",
            entry: operation,
            source_bytes: source_bytes,
            destination_bytes: destination_bytes
          )
          return
        end
        unless File.binread(source) == File.binread(destination)
          findings << finding(:content_mismatch, "Reviewed destination file content does not match artifact source.", entry: operation)
          return
        end

        verified << verification_entry(operation, applied, :verified, bytes: destination_bytes)
      end

      def report_unexpected_applied_operations
        expected_signatures = expected_verifiable_operations.map { |operation| operation_signature(operation) }.to_set
        applied_verifiable_operations.each do |operation|
          next if expected_signatures.include?(operation_signature(operation))

          findings << finding(:unexpected_operation, "Applied operation was not present in the reviewed apply plan.", entry: operation)
        end
      end

      def verification_entry(operation, applied, status, bytes: nil)
        {
          type: operation_type(operation),
          status: status,
          source: value(operation, :source),
          destination: value(operation, :destination),
          bytes: bytes,
          result_status: value(applied, :status),
          metadata: operation_metadata(operation)
        }.compact
      end

      def expected_verifiable_operations
        @expected_verifiable_operations ||= if plan_payload
                                              verifiable_operations(Array(value(plan_payload, :operations)))
                                            else
                                              applied_verifiable_operations
                                            end.freeze
      end

      def applied_verifiable_operations
        @applied_verifiable_operations ||= verifiable_operations(applied).freeze
      end

      def verifiable_operations(operations)
        operations.select { |operation| %i[ensure_directory copy_file].include?(operation_type(operation)) }
      end

      def applied_by_signature
        @applied_by_signature ||= applied_verifiable_operations.each_with_object({}) do |operation, by_signature|
          by_signature[operation_signature(operation)] = operation
        end.freeze
      end

      def operation_signature(operation)
        [
          operation_type(operation),
          value(operation, :source).to_s,
          value(operation, :destination).to_s
        ]
      end

      def source_path(operation)
        reviewed_path(value(operation, :source), artifact_root)
      end

      def destination_path(operation)
        reviewed_path(value(operation, :destination), destination_root_path)
      end

      def reviewed_path(relative, root)
        return nil unless root
        return nil unless safe_relative_path?(relative)

        path = File.expand_path(relative.to_s, root)
        inside_root?(path, root) ? path : nil
      end

      def committed?
        value(result_payload, :committed) == true
      end

      def applied
        Array(value(result_payload, :applied))
      end

      def skipped
        Array(value(result_payload, :skipped))
      end

      def non_review_skipped
        skipped.reject { |entry| operation_type(entry) == :manual_host_wiring }
      end

      def refusals
        Array(value(result_payload, :refusals))
      end

      def operation_count
        value(result_payload, :operation_count) || expected_verifiable_operations.length + skipped.length
      end

      def artifact_path
        value(result_payload, :artifact_path).to_s
      end

      def destination_root
        value(result_payload, :destination_root).to_s
      end

      def artifact_root
        @artifact_root ||= expanded_root(value(result_payload, :artifact_path))
      end

      def destination_root_path
        @destination_root_path ||= expanded_root(value(result_payload, :destination_root))
      end

      def surface_count
        value(result_payload, :surface_count) || 0
      end

      def operation_type(operation)
        type = value(operation, :type)
        type.respond_to?(:to_sym) ? type.to_sym : type
      end

      def operation_metadata(operation)
        metadata = value(operation, :metadata)
        metadata.respond_to?(:dup) ? metadata.dup : metadata
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

      def payload_from(source)
        payload = source.respond_to?(:to_h) ? source.to_h : source
        payload.to_h
      end

      def value(hash, key)
        return nil unless hash.respond_to?(:key?)
        return hash[key] if hash.key?(key)

        hash[key.to_s]
      end

      def finding(code, message, entry: nil, entries: nil, **metadata)
        {
          code: code,
          message: message,
          entry: entry,
          entries: entries,
          metadata: metadata.empty? ? nil : metadata
        }.compact
      end
    end
  end
end
