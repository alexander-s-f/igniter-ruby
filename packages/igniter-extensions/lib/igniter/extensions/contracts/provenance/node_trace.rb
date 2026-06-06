# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Provenance
        class NodeTrace
          attr_reader :name, :kind, :value, :contributing

          def initialize(name:, kind:, value:, contributing: {})
            @name = name.to_sym
            @kind = kind.to_sym
            @value = value
            @contributing = contributing.freeze
            freeze
          end

          def input?
            kind == :input
          end

          def leaf?
            contributing.empty?
          end

          def contributing_inputs
            return { name => value } if input?

            contributing.each_value.with_object({}) do |trace, memo|
              memo.merge!(trace.contributing_inputs)
            end
          end

          def sensitive_to?(input_name)
            contributing_inputs.key?(input_name.to_sym)
          end

          def path_to(input_name)
            target = input_name.to_sym
            return [name] if name == target

            contributing.each_value do |trace|
              path = trace.path_to(target)
              return [name] + path if path
            end

            nil
          end
        end
      end
    end
  end
end
