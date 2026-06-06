# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Language
        module FormulaPack
          module_function

          def manifest
            Igniter::Contracts::PackManifest.new(
              name: :extensions_language_formula,
              registry_contracts: [Igniter::Contracts::PackManifest.dsl_keyword(:formula)]
            )
          end

          def install_into(kernel)
            kernel.dsl_keywords.register(:formula, formula_keyword)
            kernel
          end

          def formula_keyword
            Igniter::Contracts::DslKeyword.new(:formula) do |name, builder:, trace: nil, &block|
              raise ArgumentError, "formula :#{name} requires a block" unless block

              trace_name = (trace || :"#{name}_trace").to_sym
              definition = Definition.new(name: name)
              definition.instance_eval(&block)
              definition.validate!

              builder.add_operation(
                kind: :compute,
                name: trace_name,
                depends_on: definition.dependencies,
                callable: lambda do |**values|
                  definition.resolve(values)
                end
              )
              builder.add_operation(
                kind: :compute,
                name: name,
                depends_on: [trace_name],
                callable: lambda do |**values|
                  values.fetch(trace_name).fetch(:value)
                end
              )
            end
          end

          class Definition
            attr_reader :dependencies

            def initialize(name:)
              @name = name.to_sym
              @steps = []
              @dependencies = []
              @has_start = false
            end

            def base(value)
              raise ArgumentError, "formula :#{@name} can define base only once" if @has_start

              @has_start = true
              @steps << { operation: :base, value: Float(value) }
            end

            def from(name)
              raise ArgumentError, "formula :#{@name} can define from only once" if @has_start

              source_name = name.to_sym
              @has_start = true
              @dependencies << source_name
              @steps << { operation: :from, source: source_name }
            end

            def add(value_or_source)
              add_numeric_or_source_step(:add, value_or_source)
            end

            def subtract(value_or_source)
              add_numeric_or_source_step(:subtract, value_or_source)
            end

            def multiply_by(value)
              @steps << { operation: :multiply_by, value: Float(value) }
            end

            def divide_by(value)
              raise ArgumentError, "formula :#{@name} divide_by cannot use zero" if Float(value).zero?

              @steps << { operation: :divide_by, value: Float(value) }
            end

            def clamp(min, max)
              minimum = Float(min)
              maximum = Float(max)
              raise ArgumentError, "formula :#{@name} clamp min cannot exceed max" if minimum > maximum

              @steps << { operation: :clamp, min: minimum, max: maximum }
            end

            def round(precision = 0)
              @steps << { operation: :round, precision: Integer(precision) }
            end

            def validate!
              raise ArgumentError, "formula :#{@name} requires base or from" unless @has_start
              raise ArgumentError, "formula :#{@name} requires at least one step" if @steps.empty?

              @dependencies.uniq!
            end

            def resolve(values)
              current = nil
              trace = []

              @steps.each do |step|
                before = current
                current = apply_step(current, step, values)
                trace << step.merge(before: before, after: current)
              end

              {
                value: current,
                dependencies: dependencies,
                steps: trace.freeze
              }
            rescue ArgumentError, TypeError
              {
                value: 0.0,
                dependencies: dependencies,
                error: :invalid_numeric_formula,
                steps: trace.freeze
              }
            end

            private

            def add_numeric_or_source_step(operation, value_or_source)
              if value_or_source.is_a?(Symbol)
                @dependencies << value_or_source
                @steps << { operation: operation, source: value_or_source }
              else
                @steps << { operation: operation, value: Float(value_or_source) }
              end
            end

            def apply_step(current, step, values)
              case step.fetch(:operation)
              when :base
                step.fetch(:value)
              when :from
                numeric_value(values.fetch(step.fetch(:source)))
              when :add
                current + operand(step, values)
              when :subtract
                current - operand(step, values)
              when :multiply_by
                current * step.fetch(:value)
              when :divide_by
                current / step.fetch(:value)
              when :clamp
                [[current, step.fetch(:min)].max, step.fetch(:max)].min
              when :round
                current.round(step.fetch(:precision))
              else
                current
              end
            end

            def operand(step, values)
              return numeric_value(values.fetch(step.fetch(:source))) if step.key?(:source)

              step.fetch(:value)
            end

            def numeric_value(value)
              Float(value)
            end
          end
        end
      end
    end
  end
end
