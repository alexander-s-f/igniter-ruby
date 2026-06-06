# frozen_string_literal: true

require_relative "workflow_step"
require_relative "writer"

module Igniter
  module Extensions
    module Contracts
      module Creator
        class Workflow
          attr_reader :report

          def initialize(report:)
            @report = report
            freeze
          end

          def scaffold
            report.scaffold
          end

          def audit
            report.audit
          end

          def profile
            scaffold.profile
          end

          def scope
            scaffold.scope
          end

          def recommended_packs
            {
              runtime: profile.runtime_dependency_hints,
              development: profile.development_dependency_hints
            }
          end

          def stages
            [
              design_stage,
              scaffold_stage,
              implementation_stage,
              validation_stage,
              packaging_stage
            ]
          end

          def current_stage
            stages.find { |stage| !stage.complete? } || stages.last
          end

          def ready_for_packaging?
            packaging_stage.status == :ready
          end

          def writer(root:, mode: :skip_existing)
            Writer.new(workflow: self, root: root, mode: mode)
          end

          def to_h
            {
              scaffold: scaffold.to_h,
              report: report.to_h,
              recommended_packs: recommended_packs,
              current_stage: current_stage.to_h,
              ready_for_packaging: ready_for_packaging?,
              stages: stages.map(&:to_h)
            }
          end

          private

          def design_stage
            hints = []
            hints << "runtime pack recommendations: #{profile.runtime_dependency_hints.join(", ")}" unless profile.runtime_dependency_hints.empty?
            hints << "development pack recommendations: #{profile.development_dependency_hints.join(", ")}" unless profile.development_dependency_hints.empty?

            WorkflowStep.new(
              key: :select_profile,
              status: :complete,
              title: "Select Authoring Profile",
              summary: "#{profile.name} -> #{profile.summary}; target scope #{scope.name}",
              hints: hints
            )
          end

          def scaffold_stage
            WorkflowStep.new(
              key: :generate_scaffold,
              status: :complete,
              title: "Generate Scaffold",
              summary: "generated #{scaffold.files.size} files rooted at #{scaffold.pack_file_path}",
              hints: scaffold.files.keys
            )
          end

          def implementation_stage
            if audit&.ok?
              WorkflowStep.new(
                key: :implement_pack,
                status: :complete,
                title: "Implement Pack",
                summary: "#{scaffold.pack_constant} satisfies the current install/finalize seam checks"
              )
            elsif audit
              WorkflowStep.new(
                key: :implement_pack,
                status: :needs_attention,
                title: "Implement Pack",
                summary: "fill the missing pack seams in #{scaffold.pack_file_path}",
                hints: implementation_hints
              )
            else
              WorkflowStep.new(
                key: :implement_pack,
                status: :ready,
                title: "Implement Pack",
                summary: "fill in #{scaffold.pack_file_path} and keep the pack on public contracts only",
                hints: report.next_steps
              )
            end
          end

          def validation_stage
            if audit&.ok?
              WorkflowStep.new(
                key: :validate_pack,
                status: :complete,
                title: "Validate Pack",
                summary: "audit passed; the pack finalizes cleanly against the current contracts profile"
              )
            elsif audit
              WorkflowStep.new(
                key: :validate_pack,
                status: :needs_attention,
                title: "Validate Pack",
                summary: "audit_pack found missing seams before finalize",
                hints: [audit.explain]
              )
            else
              WorkflowStep.new(
                key: :validate_pack,
                status: :ready,
                title: "Validate Pack",
                summary: "run audit_pack once the implementation is in place",
                hints: ["Igniter::Extensions::Contracts.audit_pack(#{scaffold.pack_constant}, environment)"]
              )
            end
          end

          def packaging_stage
            if audit&.ok?
              WorkflowStep.new(
                key: :package_pack,
                status: :ready,
                title: "Package Pack",
                summary: "the pack is ready for #{scope.name} packaging review",
                hints: scope.packaging_hints
              )
            else
              WorkflowStep.new(
                key: :package_pack,
                status: :pending,
                title: "Package Pack",
                summary: "finish implementation and validation before packaging for #{scope.name}",
                hints: scope.packaging_hints
              )
            end
          end

          def implementation_hints
            hints = []
            hints << "define node kinds: #{audit.missing_node_definitions.join(", ")}" unless audit.missing_node_definitions.empty?
            hints << "register DSL keywords: #{audit.missing_dsl_keywords.join(", ")}" unless audit.missing_dsl_keywords.empty?
            hints << "register runtime handlers: #{audit.missing_runtime_handlers.join(", ")}" unless audit.missing_runtime_handlers.empty?
            audit.missing_registry_contracts.each do |registry, keys|
              hints << "register #{registry}: #{keys.join(", ")}"
            end
            hints << "resolve finalize error: #{audit.finalize_error}" if audit.finalize_error
            hints
          end
        end
      end
    end
  end
end
