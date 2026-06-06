# frozen_string_literal: true

require_relative "incremental_pack"
require_relative "dataflow/aggregate_operators"
require_relative "dataflow/aggregate_state"
require_relative "dataflow/builder"
require_relative "dataflow/collection_result"
require_relative "dataflow/diff"
require_relative "dataflow/item_result"
require_relative "dataflow/result"
require_relative "dataflow/session"
require_relative "dataflow/window_filter"

module Igniter
  module Extensions
    module Contracts
      module DataflowPack
        module_function

        def manifest
          Igniter::Contracts::PackManifest.new(
            name: :extensions_dataflow,
            metadata: { category: :orchestration }
          )
        end

        def install_into(kernel)
          kernel
        end

        def session(environment, source:, key:, window: nil, context: [], compiled_graph: nil, &block)
          ensure_installed!(environment.profile)
          Igniter::Extensions::Contracts::IncrementalPack.ensure_installed!(environment.profile)

          item_graph, aggregate_operators =
            if compiled_graph
              raise ArgumentError, "DataflowPack.session accepts either compiled_graph: or a block, not both" if block

              [compiled_graph, {}]
            else
              builder = Dataflow::Builder.new(source: source, key: key, window: window, context: context)
              builder.instance_eval(&block) if block
              builder.build!(environment)
            end

          Dataflow::Session.new(
            environment: environment,
            compiled_graph: item_graph,
            source: source,
            key: key,
            window: window,
            context: context,
            aggregate_operators: aggregate_operators
          )
        end

        def ensure_installed!(profile)
          return if profile.pack_names.include?(:extensions_dataflow)

          raise Igniter::Contracts::Error,
                "DataflowPack is not installed in profile #{profile.fingerprint}; add Igniter::Extensions::Contracts::DataflowPack"
        end
      end
    end
  end
end
