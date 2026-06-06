# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Dataflow
        class ItemResult
          attr_reader :key, :inputs, :execution_result, :incremental_result

          def initialize(key:, inputs:, execution_result:, incremental_result:)
            @key = key
            @inputs = Igniter::Contracts::NamedValues.new(inputs)
            @execution_result = execution_result
            @incremental_result = incremental_result
            freeze
          end

          alias result execution_result

          def input(name)
            inputs.fetch(name)
          end

          def output(name)
            execution_result.output(name)
          end

          def outputs
            execution_result.outputs
          end

          def to_h
            {
              key: key,
              inputs: inputs.to_h,
              execution_result: execution_result.to_h,
              incremental_result: incremental_result.to_h
            }
          end
        end
      end
    end
  end
end
