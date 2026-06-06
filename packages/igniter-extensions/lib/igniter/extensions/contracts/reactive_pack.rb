# frozen_string_literal: true

require_relative "reactive/event"
require_relative "reactive/subscription"
require_relative "reactive/matcher"
require_relative "reactive/plan"
require_relative "reactive/builder"
require_relative "reactive/dispatch_result"
require_relative "reactive/engine"

module Igniter
  module Extensions
    module Contracts
      module ReactivePack
        module_function

        def manifest
          Igniter::Contracts::PackManifest.new(
            name: :extensions_reactive,
            metadata: { category: :orchestration }
          )
        end

        def install_into(kernel)
          kernel
        end

        def build(&block)
          Reactive::Builder.build(&block)
        end

        def dispatch(target, reactions:)
          result = target
          execution_result = unwrap_execution_result(target)
          events = build_events(target, execution_result: execution_result)

          engine = Reactive::Engine.new(plan: reactions)
          engine.call(events: events, result: result, execution_result: execution_result)

          Reactive::DispatchResult.new(
            status: :succeeded,
            events: events,
            errors: engine.errors,
            result: result,
            execution_result: execution_result
          )
        end

        def run(environment, inputs:, reactions:, compiled_graph: nil, &block)
          graph =
            if block
              environment.compile(&block)
            else
              compiled_graph || raise(ArgumentError, "reactive run requires a block or compiled_graph")
            end

          begin
            result = environment.execute(graph, inputs: inputs)
            dispatch(result, reactions: reactions)
          rescue StandardError => e
            dispatch_failure(e, reactions: reactions)
          end
        end

        def run_incremental(session, inputs:, reactions:)
          result = session.run(inputs: inputs)
          dispatch(result, reactions: reactions)
        end

        def dispatch_failure(error, reactions:)
          events = [
            Reactive::Event.new(
              event_id: "execution_failed",
              type: :execution_failed,
              path: :execution,
              status: :failed,
              payload: {
                error_type: error.class.name,
                error_message: error.message
              }
            ),
            Reactive::Event.new(
              event_id: "execution_exited",
              type: :execution_exited,
              path: :execution,
              status: :failed,
              payload: {
                error_type: error.class.name,
                error_message: error.message
              }
            )
          ]

          engine = Reactive::Engine.new(plan: reactions)
          engine.call(events: events, result: nil, execution_result: nil, execution_error: error)

          Reactive::DispatchResult.new(
            status: :failed,
            events: events,
            errors: engine.errors,
            result: nil,
            execution_result: nil,
            execution_error: error
          )
        end

        def unwrap_execution_result(target)
          return target.execution_result if target.respond_to?(:execution_result)

          target
        end

        def build_events(target, execution_result:)
          events = []

          events << Reactive::Event.new(
            event_id: "execution_succeeded",
            type: :execution_succeeded,
            path: :execution,
            status: :succeeded,
            payload: {
              output_names: execution_result.outputs.keys
            }
          )

          execution_result.outputs.to_h.each do |name, value|
            events << Reactive::Event.new(
              event_id: "output_produced:#{name}",
              type: :output_produced,
              path: name,
              status: :succeeded,
              payload: {
                value: value
              }
            )
          end

          if target.respond_to?(:changed_outputs)
            target.changed_outputs.each do |name, change|
              events << Reactive::Event.new(
                event_id: "output_changed:#{name}",
                type: :output_changed,
                path: name,
                status: :succeeded,
                payload: {
                  value: execution_result.output(name),
                  previous_value: change[:from],
                  current_value: change[:to]
                }
              )
            end
          end

          events << Reactive::Event.new(
            event_id: "execution_exited",
            type: :execution_exited,
            path: :execution,
            status: :succeeded,
            payload: {
              output_names: execution_result.outputs.keys
            }
          )

          events.freeze
        end
      end
    end
  end
end
