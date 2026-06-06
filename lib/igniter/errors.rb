# frozen_string_literal: true

module Igniter
  unless const_defined?(:Error)
    class Error < StandardError
      attr_reader :context

      def initialize(message = nil, context: {})
        @context = context.compact.freeze
        super(format_message(message, @context))
      end

      def graph
        context[:graph]
      end

      def node_id
        context[:node_id]
      end

      def node_name
        context[:node_name]
      end

      def node_path
        context[:node_path]
      end

      def source_location
        context[:source_location]
      end

      def execution_id
        context[:execution_id]
      end

      private

      def format_message(message, context)
        details = []
        details << "graph=#{context[:graph]}" if context[:graph]
        details << "node=#{context[:node_name]}" if context[:node_name]
        details << "path=#{context[:node_path]}" if context[:node_path]
        details << "execution=#{context[:execution_id]}" if context[:execution_id]
        details << "location=#{context[:source_location]}" if context[:source_location]

        return message if details.empty?

        "#{message} [#{details.join(", ")}]"
      end
    end

    class CompileError < Error; end
    class ValidationError < CompileError; end
    class CycleError < ValidationError; end
    class InputError < Error; end
    class CollectionInputError < Error; end
    class CollectionKeyError < Error; end
    class ResolutionError < Error; end
    class CompositionError < Error; end
    class BranchSelectionError < Error; end

    class PendingDependencyError < Error
      attr_reader :deferred_result

      def initialize(deferred_result, message = "Dependency is pending", context: {}, token: nil, source_node: nil,
                     waiting_on: nil, payload: nil)
        @deferred_result, resolved_message = normalize_pending_deferred(
          deferred_result,
          message,
          token: token,
          source_node: source_node,
          waiting_on: waiting_on,
          payload: payload
        )
        super(resolved_message, context: context)
      end

      private

      def normalize_pending_deferred(deferred_result, message, token:, source_node:, waiting_on:, payload:)
        deferred_class = defined?(Igniter::Runtime::DeferredResult) ? Igniter::Runtime::DeferredResult : nil
        return [deferred_result, message] if deferred_class && deferred_result.is_a?(deferred_class)

        built_deferred = deferred_class&.build(
          token: token,
          source_node: source_node,
          waiting_on: waiting_on || source_node,
          payload: payload || {}
        )

        [built_deferred || deferred_result, deferred_result]
      end
    end

    class InvariantError < Error
      attr_reader :violations

      def initialize(message = nil, violations: [], context: {})
        @violations = violations.freeze
        super(message, context: context)
      end
    end
  end
end
