# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationTransferReadiness
      DEFAULT_POLICY = {
        missing_expected_paths: :blocker
      }.freeze

      attr_reader :handoff_manifest, :transfer_inventory, :policy, :metadata,
                  :manifest_payload, :inventory_payload, :blockers, :warnings

      def self.build(handoff_manifest: nil, transfer_inventory: nil, capsules: [], subject: :capsule_transfer,
                     host_exports: [], host_capabilities: [], mount_intents: [], surface_metadata: [],
                     enumerate_files: true, policy: {}, metadata: {})
        blueprints = capsules.map { |entry| entry.respond_to?(:to_blueprint) ? entry.to_blueprint : entry }
        manifest = handoff_manifest || ApplicationHandoffManifest.build(
          subject: subject,
          capsules: blueprints,
          host_exports: host_exports,
          host_capabilities: host_capabilities,
          mount_intents: mount_intents,
          surface_metadata: surface_metadata
        )
        inventory = transfer_inventory || ApplicationTransferInventory.build(
          capsules: blueprints,
          surface_metadata: surface_metadata,
          enumerate_files: enumerate_files
        )

        new(
          handoff_manifest: manifest,
          transfer_inventory: inventory,
          policy: policy,
          metadata: metadata
        )
      end

      def initialize(handoff_manifest:, transfer_inventory:, policy: {}, metadata: {})
        @handoff_manifest = handoff_manifest
        @transfer_inventory = transfer_inventory
        @policy = DEFAULT_POLICY.merge(policy).freeze
        @metadata = metadata.dup.freeze
        @manifest_payload = handoff_manifest.to_h
        @inventory_payload = transfer_inventory.to_h
        @blockers, @warnings = build_findings.partition { |entry| entry.fetch(:severity) == :blocker }
        @blockers = @blockers.freeze
        @warnings = @warnings.freeze
        freeze
      end

      def ready?
        blockers.empty?
      end

      def to_h
        {
          ready: ready?,
          blockers: blockers.map(&:dup),
          warnings: warnings.map(&:dup),
          summary: summary,
          manifest: manifest_payload,
          inventory: inventory_payload,
          metadata: metadata.dup
        }
      end

      private

      def build_findings
        manifest_blockers + agent_findings + inventory_findings + surface_metadata_warnings + inventory_warnings + optional_warnings
      end

      def manifest_blockers
        findings = []
        manifest_payload.fetch(:unresolved_required_imports, []).each do |entry|
          findings << finding(
            severity: :blocker,
            source: :manifest,
            code: :unresolved_required_import,
            message: "Required import #{entry.fetch(:name)} for #{entry.fetch(:capsule)} is unresolved.",
            metadata: entry
          )
        end
        manifest_payload.fetch(:unresolved_mount_intents, []).each do |entry|
          findings << finding(
            severity: :blocker,
            source: :manifest,
            code: :unresolved_mount_intent,
            message: "Mount intent for capsule #{entry.fetch(:capsule)} does not reference a declared capsule.",
            metadata: entry
          )
        end
        if !manifest_payload.fetch(:ready) && findings.empty?
          findings << finding(
            severity: :blocker,
            source: :manifest,
            code: :manifest_not_ready,
            message: "Handoff manifest is not ready.",
            metadata: { ready: false }
          )
        end
        findings
      end

      def inventory_findings
        inventory_payload.fetch(:capsules, []).flat_map do |capsule|
          skipped_path_findings(capsule) + missing_path_findings(capsule)
        end
      end

      def agent_findings
        manifest_payload.fetch(:capsules, []).flat_map do |capsule|
          capsule.fetch(:agents, []).filter_map do |agent|
            next if agent_ai_provider_declared?(capsule, agent)

            finding(
              severity: :blocker,
              source: :agents,
              code: :missing_agent_ai_provider,
              message: "Agent #{agent.fetch(:name)} for #{capsule.fetch(:name)} requires AI provider #{agent.fetch(:ai_provider)}.",
              metadata: {
                capsule: capsule.fetch(:name),
                agent: agent.fetch(:name),
                ai_provider: agent.fetch(:ai_provider)
              }
            )
          end
        end
      end

      def skipped_path_findings(capsule)
        capsule.fetch(:skipped_paths, []).map do |entry|
          finding(
            severity: :blocker,
            source: :inventory,
            code: :skipped_unsafe_path,
            message: "Expected path #{entry.fetch(:path)} for #{capsule.fetch(:name)} is outside the capsule root.",
            metadata: entry.merge(capsule: capsule.fetch(:name))
          )
        end
      end

      def missing_path_findings(capsule)
        severity = missing_expected_path_severity
        capsule.fetch(:missing_expected_paths, []).map do |entry|
          finding(
            severity: severity,
            source: :inventory,
            code: :missing_expected_path,
            message: "Expected #{entry.fetch(:kind)} path #{entry.fetch(:path)} for #{capsule.fetch(:name)} is missing.",
            metadata: entry.merge(capsule: capsule.fetch(:name))
          )
        end
      end

      def missing_expected_path_severity
        policy.fetch(:missing_expected_paths).to_sym == :warning ? :warning : :blocker
      end

      def surface_metadata_warnings
        declared_surfaces.each_with_object([]) do |(capsule, surface), findings|
          next if supplied_surface_names.include?(surface)

          findings << finding(
            severity: :warning,
            source: :surface_metadata,
            code: :surface_metadata_absent,
            message: "Surface metadata for #{surface} on #{capsule} was not supplied.",
            metadata: { capsule: capsule, surface: surface }
          )
        end
      end

      def inventory_warnings
        return [] if inventory_payload.fetch(:files_enumerated)

        [
          finding(
            severity: :warning,
            source: :inventory,
            code: :files_not_enumerated,
            message: "Transfer inventory file enumeration was deferred.",
            metadata: { files_enumerated: false }
          )
        ]
      end

      def optional_warnings
        manifest_payload.fetch(:missing_optional_imports, []).map do |entry|
          finding(
            severity: :warning,
            source: :manifest,
            code: :missing_optional_import,
            message: "Optional import #{entry.fetch(:name)} for #{entry.fetch(:capsule)} is not wired.",
            metadata: entry
          )
        end
      end

      def declared_surfaces
        manifest_payload.fetch(:capsules, []).flat_map do |capsule|
          capsule.fetch(:web_surfaces, []).map { |surface| [capsule.fetch(:name), surface.to_sym] }
        end
      end

      def agent_ai_provider_declared?(capsule, agent)
        provider = agent.fetch(:ai_provider).to_sym
        return true if provider == :default && capsule.fetch(:providers, []).empty?
        return true if capsule.fetch(:providers, []).map(&:to_sym).include?(provider)

        capsule.fetch(:imports, []).any? do |entry|
          entry.fetch(:name).to_sym == provider && entry.fetch(:kind).to_sym == :ai_provider
        end
      end

      def supplied_surface_names
        (
          manifest_payload.fetch(:surfaces, []) + inventory_payload.fetch(:surfaces, [])
        ).filter_map { |entry| surface_name(entry) }.uniq
      end

      def surface_name(entry)
        name = entry[:name] || entry["name"]
        name&.to_sym
      end

      def summary
        {
          blocker_count: blockers.length,
          warning_count: warnings.length,
          sources: source_counts,
          manifest_ready: manifest_payload.fetch(:ready),
          inventory_ready: inventory_payload.fetch(:ready),
          unresolved_required_count: manifest_payload.fetch(:unresolved_required_imports, []).length,
          unresolved_mount_count: manifest_payload.fetch(:unresolved_mount_intents, []).length,
          missing_expected_path_count: inventory_payload.fetch(:missing_path_count),
          skipped_path_count: inventory_payload.fetch(:skipped_path_count),
          supplied_surface_count: supplied_surface_names.length
        }
      end

      def source_counts
        (blockers + warnings).each_with_object(Hash.new(0)) do |entry, memo|
          memo[entry.fetch(:source)] += 1
        end.to_h
      end

      def finding(severity:, source:, code:, message:, metadata: {})
        {
          severity: severity.to_sym,
          source: source.to_sym,
          code: code.to_sym,
          message: message,
          metadata: metadata.dup
        }
      end
    end
  end
end
