# frozen_string_literal: true

require_relative "saga/compensation"
require_relative "saga/compensation_record"
require_relative "saga/compensation_set"
require_relative "saga/formatter"
require_relative "saga/result"
require_relative "saga/runner"

module Igniter
  module Extensions
    module Contracts
      module SagaPack
        module_function

        def manifest
          Igniter::Contracts::PackManifest.new(
            name: :extensions_saga,
            metadata: { category: :orchestration }
          )
        end

        def install_into(kernel)
          kernel
        end

        def build(&block)
          Saga::CompensationSet.build(&block)
        end

        def run(environment, inputs:, compensations:, compiled_graph: nil, &block)
          profile = environment.profile
          ensure_installed!(profile)
          graph = compiled_graph || environment.compile(&block)

          Saga::Runner.new(
            compiled_graph: graph,
            profile: profile,
            compensations: compensations
          ).run(inputs: inputs)
        end

        def explain(result)
          result.explain
        end

        def ensure_installed!(profile)
          return if profile.pack_names.include?(:extensions_saga)

          raise Saga::SagaError,
                "SagaPack is not installed in profile #{profile.fingerprint}; add Igniter::Extensions::Contracts::SagaPack"
        end
      end
    end
  end
end
