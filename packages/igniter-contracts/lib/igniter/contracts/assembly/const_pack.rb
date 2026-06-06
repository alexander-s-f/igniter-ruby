# frozen_string_literal: true

module Igniter
  module Contracts
    module Assembly
      module ConstPack
        module_function

        def manifest
          PackManifest.new(
            name: :const,
            node_contracts: [PackManifest.node(:const)]
          )
        end

        def install_into(kernel)
          return kernel if kernel.nodes.registered?(:const)

          kernel.nodes.register(:const, NodeType.new(kind: :const, metadata: { category: :value }))
          kernel.dsl_keywords.register(:const, DslKeyword.new(:const) do |name, value, builder:|
            builder.add_operation(kind: :const, name: name, value: value)
          end)
          kernel.runtime_handlers.register(:const, Execution::ConstRuntime.method(:handle_const))
          kernel
        end
      end
    end
  end
end
