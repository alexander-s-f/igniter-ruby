# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      module BaselineValidators
        module_function

        def validate_uniqueness(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
          names = operations.reject(&:output?).map(&:name)
          duplicates = names.group_by(&:itself).select { |_name, entries| entries.length > 1 }.keys
          return [] if duplicates.empty?

          [ValidationFinding.new(
            code: :duplicate_node_names,
            message: "duplicate node names: #{duplicates.map(&:to_s).join(", ")}",
            subjects: duplicates
          )]
        end

        def validate_outputs(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
          available = operations.reject(&:output?).map(&:name)
          missing = operations.select(&:output?)
                              .map(&:name)
                              .reject { |name| available.include?(name) }
          return [] if missing.empty?

          [ValidationFinding.new(
            code: :missing_output_targets,
            message: "output targets are not defined: #{missing.map(&:to_s).join(", ")}",
            subjects: missing
          )]
        end

        def validate_dependencies(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
          available = operations.reject(&:output?).map(&:name)
          missing = operations.select { |operation| operation.kind == :compute }
                              .flat_map { |operation| Array(operation.attributes[:depends_on]) }
                              .map(&:to_sym)
                              .reject { |name| available.include?(name) }
                              .uniq
          return [] if missing.empty?

          [ValidationFinding.new(
            code: :missing_compute_dependencies,
            message: "compute dependencies are not defined: #{missing.map(&:to_s).join(", ")}",
            subjects: missing
          )]
        end

        def validate_callables(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
          missing = operations.select { |operation| operation.kind == :compute }
                              .reject { |operation| operation.attributes[:callable].respond_to?(:call) }
                              .map(&:name)
          return [] if missing.empty?

          [ValidationFinding.new(
            code: :missing_compute_callable,
            message: "compute nodes require a callable: #{missing.map(&:to_s).join(", ")}",
            subjects: missing
          )]
        end

        def validate_effect_dependencies(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
          available = operations.reject(&:output?).map(&:name)
          missing = operations.select { |operation| operation.kind == :effect }
                              .flat_map { |operation| Array(operation.attributes[:depends_on]) }
                              .map(&:to_sym)
                              .reject { |name| available.include?(name) }
                              .uniq
          return [] if missing.empty?

          [ValidationFinding.new(
            code: :missing_effect_dependencies,
            message: "effect dependencies are not defined: #{missing.map(&:to_s).join(", ")}",
            subjects: missing
          )]
        end

        def validate_effect_payload_builders(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
          missing = operations.select { |operation| operation.kind == :effect }
                              .reject { |operation| operation.attributes[:callable].respond_to?(:call) }
                              .map(&:name)
          return [] if missing.empty?

          [ValidationFinding.new(
            code: :missing_effect_payload_builder,
            message: "effect nodes require a payload callable: #{missing.map(&:to_s).join(", ")}",
            subjects: missing
          )]
        end

        def validate_effect_adapters(operations:, profile:)
          missing = operations.select { |operation| operation.kind == :effect }
                              .map { |operation| operation.attributes[:using] }
                              .reject { |effect_name| profile.supports_effect?(effect_name) }
                              .uniq
          return [] if missing.empty?

          [ValidationFinding.new(
            code: :unknown_effect_adapters,
            message: "effect adapters are not registered in profile: #{missing.map(&:to_s).join(", ")}",
            subjects: missing
          )]
        end

        def validate_types(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
          []
        end
      end
    end
  end
end
