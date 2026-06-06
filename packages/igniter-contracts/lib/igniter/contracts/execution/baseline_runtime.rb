# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      module BaselineRuntime
        module_function

        def handle_input(operation:, inputs:, **)
          inputs.fetch(operation.name)
        end

        def handle_compute(operation:, state:, **)
          callable = operation.attributes[:callable]
          kwargs = resolve_dependency_values(operation, state: state)
          callable.call(**kwargs)
        end

        def handle_effect(operation:, state:, profile:, **)
          callable = operation.attributes[:callable]
          effect_name = operation.attributes.fetch(:using).to_sym
          dependency_values = resolve_dependency_values(operation, state: state)
          payload = callable.call(**dependency_values)
          invocation = EffectInvocation.new(
            payload: payload,
            context: {
              node_name: operation.name,
              effect_name: effect_name,
              dependencies: dependency_values
            },
            profile: profile
          )

          profile.effect(effect_name).call(invocation: invocation)
        end

        def handle_output(operation:, state:, **)
          state.fetch(operation.name)
        end

        def unsupported(kind)
          lambda do |**|
            raise NotImplementedError, "#{kind} runtime handler is not implemented in the baseline runtime yet"
          end
        end

        def resolve_dependency_values(operation, state:)
          Array(operation.attributes[:depends_on]).each_with_object({}) do |dependency, memo|
            memo[dependency.to_sym] = state.fetch(dependency.to_sym)
          end
        end
      end
    end
  end
end
