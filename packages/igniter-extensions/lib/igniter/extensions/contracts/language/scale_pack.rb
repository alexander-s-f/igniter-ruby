# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Language
        module ScalePack
          module_function

          def manifest
            Igniter::Contracts::PackManifest.new(
              name: :extensions_language_scale,
              registry_contracts: [Igniter::Contracts::PackManifest.dsl_keyword(:scale)]
            )
          end

          def install_into(kernel)
            kernel.dsl_keywords.register(:scale, scale_keyword)
            kernel
          end

          def scale_keyword
            Igniter::Contracts::DslKeyword.new(:scale) do |name, from:, builder:, trace: nil, &block|
              raise ArgumentError, "scale :#{name} requires a block" unless block

              source_name = from.to_sym
              trace_name = (trace || :"#{name}_trace").to_sym
              definition = Definition.new(name: name, source_name: source_name)
              definition.instance_eval(&block)
              definition.validate!

              builder.add_operation(
                kind: :compute,
                name: trace_name,
                depends_on: [source_name],
                callable: lambda do |**values|
                  definition.resolve(values.fetch(source_name))
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
            def initialize(name:, source_name:)
              @name = name.to_sym
              @source_name = source_name.to_sym
              @steps = []
            end

            def divide_by(value)
              raise ArgumentError, "scale :#{@name} divide_by cannot use zero" if Float(value).zero?

              add_step(:divide_by, value)
            end

            def multiply_by(value)
              add_step(:multiply_by, value)
            end

            def add(value)
              add_step(:add, value)
            end

            def subtract(value)
              add_step(:subtract, value)
            end

            def clamp(min, max)
              minimum = Float(min)
              maximum = Float(max)
              raise ArgumentError, "scale :#{@name} clamp min cannot exceed max" if minimum > maximum

              @steps << { operation: :clamp, min: minimum, max: maximum }
            end

            def round(precision = 0)
              @steps << { operation: :round, precision: Integer(precision) }
            end

            def validate!
              raise ArgumentError, "scale :#{@name} requires at least one step" if @steps.empty?
            end

            def resolve(source_value)
              current = Float(source_value)
              trace = []

              @steps.each do |step|
                before = current
                current = apply_step(current, step)
                trace << step.merge(before: before, after: current)
              end

              {
                value: current,
                source: @source_name,
                source_value: source_value,
                steps: trace.freeze
              }
            rescue ArgumentError, TypeError
              {
                value: 0.0,
                source: @source_name,
                source_value: source_value,
                error: :invalid_numeric_source,
                steps: trace.freeze
              }
            end

            private

            def add_step(operation, value)
              @steps << { operation: operation, value: Float(value) }
            end

            def apply_step(current, step)
              case step.fetch(:operation)
              when :divide_by
                current / step.fetch(:value)
              when :multiply_by
                current * step.fetch(:value)
              when :add
                current + step.fetch(:value)
              when :subtract
                current - step.fetch(:value)
              when :clamp
                [[current, step.fetch(:min)].max, step.fetch(:max)].min
              when :round
                current.round(step.fetch(:precision))
              else
                current
              end
            end
          end
        end
      end
    end
  end
end
