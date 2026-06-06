# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      class Compiler
        class << self
          def compile(profile:, &block)
            compilation_report(profile: profile, &block).to_compiled_graph
          end

          def compilation_report(profile:, &block)
            builder = Builder.build(profile: profile, &block)
            operations = normalize(builder.operations, profile: profile)
            findings = validate(operations, profile: profile)
            validation_report = ValidationReport.new(
              operations: operations,
              findings: findings,
              profile_fingerprint: profile.fingerprint
            )
            compiled_graph = if validation_report.ok?
                               CompiledGraph.new(operations: operations,
                                                 profile_fingerprint: profile.fingerprint)
                             end

            CompilationReport.new(
              operations: operations,
              validation_report: validation_report,
              compiled_graph: compiled_graph,
              profile_fingerprint: profile.fingerprint
            )
          end

          def validation_report(profile:, &block)
            compilation_report(profile: profile, &block).validation_report
          end

          private

          def normalize(operations, profile:)
            hook_spec = Assembly::HookSpecs.fetch(:normalizers)

            profile.normalizers.each do |entry|
              operations = entry.value.call(operations: operations, profile: profile)
              operations = hook_spec.validate_result!(entry.key, operations)
            end
            operations
          end

          def validate(operations, profile:)
            hook_spec = Assembly::HookSpecs.fetch(:validators)
            findings = []

            profile.validators.each do |entry|
              validator_findings = entry.value.call(operations: operations, profile: profile)
              validated_findings = hook_spec.validate_result!(entry.key, validator_findings)
              findings.concat(validated_findings || [])
            end

            findings
          end
        end
      end
    end
  end
end
