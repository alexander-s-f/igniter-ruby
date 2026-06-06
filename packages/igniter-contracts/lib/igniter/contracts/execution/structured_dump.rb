# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      module StructuredDump
        module_function

        def dump(value)
          case value
          when Array
            value.map { |entry| dump(entry) }
          when Hash
            value.to_h { |key, entry| [normalize_key(key), dump(entry)] }
          else
            dump_object(value)
          end
        end

        def dump_object(value)
          if serializable_contract_object?(value)
            value.to_h
          else
            value
          end
        end

        def serializable_contract_object?(value)
          value.is_a?(NamedValues) ||
            value.is_a?(Operation) ||
            value.is_a?(CompiledGraph) ||
            value.is_a?(ExecutionResult) ||
            value.is_a?(EffectInvocation) ||
            value.is_a?(ExecutionRequest) ||
            value.is_a?(DiagnosticsSection) ||
            value.is_a?(DiagnosticsReport) ||
            value.is_a?(ValidationFinding) ||
            value.is_a?(ValidationReport) ||
            value.is_a?(CompilationReport) ||
            (defined?(StepResult) && value.is_a?(StepResult))
        end

        def normalize_key(key)
          key.respond_to?(:to_sym) ? key.to_sym : key
        end
      end
    end
  end
end
