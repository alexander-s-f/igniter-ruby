# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationTransferBundlePlan
      DEFAULT_POLICY = {
        allow_not_ready: false
      }.freeze

      attr_reader :transfer_readiness, :policy, :metadata, :readiness_payload

      def self.build(transfer_readiness: nil, handoff_manifest: nil, transfer_inventory: nil,
                     capsules: [], subject: :capsule_transfer, host_exports: [], host_capabilities: [],
                     mount_intents: [], surface_metadata: [], enumerate_files: true, readiness_policy: {},
                     policy: {}, metadata: {})
        readiness = transfer_readiness || ApplicationTransferReadiness.build(
          handoff_manifest: handoff_manifest,
          transfer_inventory: transfer_inventory,
          capsules: capsules.map { |entry| entry.respond_to?(:to_blueprint) ? entry.to_blueprint : entry },
          subject: subject,
          host_exports: host_exports,
          host_capabilities: host_capabilities,
          mount_intents: mount_intents,
          surface_metadata: surface_metadata,
          enumerate_files: enumerate_files,
          policy: readiness_policy
        )

        new(transfer_readiness: readiness, policy: policy, metadata: metadata)
      end

      def initialize(transfer_readiness:, policy: {}, metadata: {})
        @transfer_readiness = transfer_readiness
        @policy = normalize_policy(policy)
        @metadata = metadata.dup.freeze
        @readiness_payload = transfer_readiness.to_h
        freeze
      end

      def ready?
        readiness_payload.fetch(:ready)
      end

      def bundle_allowed?
        ready? || policy.fetch(:allow_not_ready)
      end

      def to_h
        {
          subject: subject,
          ready: ready?,
          bundle_allowed: bundle_allowed?,
          capsules: capsules,
          included_files: included_files,
          included_file_count: included_file_count,
          missing_paths: missing_paths,
          missing_path_count: missing_paths.length,
          surfaces: surfaces,
          blockers: readiness_payload.fetch(:blockers),
          warnings: readiness_payload.fetch(:warnings),
          policy: policy.dup,
          readiness: readiness_payload,
          metadata: metadata.dup
        }
      end

      private

      def normalize_policy(value)
        DEFAULT_POLICY.merge(value).transform_values { |entry| entry == true }.freeze
      end

      def subject
        readiness_payload.fetch(:manifest).fetch(:subject)
      end

      def capsules
        readiness_payload.fetch(:inventory).fetch(:capsules).map do |entry|
          {
            name: entry.fetch(:name),
            root: entry.fetch(:root),
            layout_profile: entry.fetch(:layout_profile),
            active_groups: entry.fetch(:active_groups),
            file_count: entry.fetch(:file_count),
            missing_path_count: entry.fetch(:missing_count),
            skipped_path_count: entry.fetch(:skipped_count)
          }
        end
      end

      def included_files
        return [] unless readiness_payload.fetch(:inventory).fetch(:files_enumerated)

        files = readiness_payload.fetch(:inventory).fetch(:capsules).flat_map do |capsule|
          capsule.fetch(:files).map do |entry|
            entry.merge(capsule: capsule.fetch(:name))
          end
        end

        files.sort_by { |entry| [entry.fetch(:capsule).to_s, entry.fetch(:relative_path)] }
      end

      def included_file_count
        return :not_enumerated unless readiness_payload.fetch(:inventory).fetch(:files_enumerated)

        included_files.length
      end

      def missing_paths
        readiness_payload.fetch(:inventory).fetch(:capsules).flat_map do |capsule|
          capsule.fetch(:missing_expected_paths).map do |entry|
            entry.merge(capsule: capsule.fetch(:name))
          end
        end
      end

      def surfaces
        (
          readiness_payload.fetch(:manifest).fetch(:surfaces) +
          readiness_payload.fetch(:inventory).fetch(:surfaces)
        ).uniq { |entry| [entry[:name] || entry["name"], entry[:kind] || entry["kind"], entry[:path] || entry["path"]] }
      end
    end
  end
end
