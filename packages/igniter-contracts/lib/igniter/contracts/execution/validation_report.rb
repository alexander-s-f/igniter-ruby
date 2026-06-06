# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      class ValidationReport
        attr_reader :operations, :findings, :profile_fingerprint

        def initialize(operations:, findings:, profile_fingerprint:)
          @operations = operations.freeze
          @findings = findings.freeze
          @profile_fingerprint = profile_fingerprint
          freeze
        end

        def ok?
          findings.empty?
        end

        def invalid?
          !ok?
        end

        def raise_if_invalid!
          return self if ok?

          raise ValidationError.new(findings: findings)
        end

        def to_compiled_graph
          raise_if_invalid!
          CompiledGraph.new(operations: operations, profile_fingerprint: profile_fingerprint)
        end

        def to_h
          {
            operations: StructuredDump.dump(operations),
            findings: StructuredDump.dump(findings),
            profile_fingerprint: profile_fingerprint,
            ok: ok?
          }
        end
      end
    end
  end
end
