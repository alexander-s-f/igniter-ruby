# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationHandoffManifest
      attr_reader :subject, :blueprints, :assembly_plan, :metadata

      def self.build(subject:, capsules: [], assembly_plan: nil, host_exports: [], host_capabilities: [],
                     mount_intents: [], surface_metadata: [], metadata: {})
        blueprints = capsules.map { |entry| entry.respond_to?(:to_blueprint) ? entry.to_blueprint : entry }
        plan = assembly_plan || ApplicationAssemblyPlan.build(
          capsules: blueprints,
          host_exports: host_exports,
          host_capabilities: host_capabilities,
          mount_intents: mount_intents,
          surface_metadata: surface_metadata
        )
        new(subject: subject, blueprints: blueprints.empty? ? plan.blueprints : blueprints,
            assembly_plan: plan, metadata: metadata)
      end

      def initialize(subject:, blueprints:, assembly_plan:, metadata: {})
        @subject = subject.to_sym
        @blueprints = Array(blueprints).freeze
        @assembly_plan = assembly_plan
        @metadata = metadata.dup.freeze
        freeze
      end

      def ready?
        assembly_plan.ready?
      end

      def to_h
        assembly = assembly_plan.to_h
        composition = assembly.fetch(:composition)
        {
          subject: subject,
          ready: ready?,
          capsule_count: blueprints.length,
          capsules: capsule_summaries,
          exports: composition.fetch(:exports),
          imports: composition.fetch(:imports),
          readiness: readiness_from(assembly, composition),
          unresolved_required_imports: composition.fetch(:unresolved_required_imports),
          missing_optional_imports: composition.fetch(:missing_optional_imports),
          suggested_host_wiring: suggested_host_wiring(composition),
          mount_intents: assembly.fetch(:mount_intents),
          unresolved_mount_intents: assembly.fetch(:unresolved_mount_intents),
          surfaces: assembly.fetch(:surfaces),
          assembly: assembly,
          metadata: metadata.dup
        }
      end

      private

      def capsule_summaries
        blueprints.map do |blueprint|
          {
            name: blueprint.name,
            root: blueprint.root,
            env: blueprint.env,
            layout_profile: blueprint.layout_profile,
            exports: blueprint.exports.map(&:to_h),
            imports: blueprint.imports.map(&:to_h),
            providers: blueprint.providers.dup,
            feature_slices: blueprint.feature_slices.map(&:to_h),
            flow_declarations: blueprint.flow_declarations.map(&:to_h),
            agents: blueprint.agents.map(&:dup),
            web_surfaces: blueprint.web_surfaces.dup
          }
        end
      end

      def readiness_from(assembly, composition)
        {
          composition_ready: assembly.fetch(:composition_ready),
          assembly_ready: assembly.fetch(:ready),
          unresolved_required_count: composition.fetch(:unresolved_required_imports).length,
          missing_optional_count: composition.fetch(:missing_optional_imports).length,
          unresolved_mount_count: assembly.fetch(:unresolved_mount_intents).length
        }
      end

      def suggested_host_wiring(composition)
        composition.fetch(:unresolved_required_imports).map do |entry|
          {
            capsule: entry.fetch(:capsule),
            name: entry.fetch(:name),
            kind: entry.fetch(:kind),
            from: entry[:from],
            capabilities: entry.fetch(:capabilities, []),
            metadata: entry.fetch(:metadata, {}).dup
          }
        end
      end
    end
  end
end
