# frozen_string_literal: true

module Igniter
  module Application
    class CollectionInvoker
      def initialize(environment:, invoker: Igniter::Extensions::Contracts::CollectionPack::LocalInvoker,
                     namespace: :collection, metadata: {}, id_generator: nil)
        @environment = environment
        @invoker = invoker
        @namespace = namespace.to_s
        @metadata = metadata.dup.freeze
        @id_generator = id_generator
        @sequence = 0
        @mutex = Mutex.new
      end

      def call(invocation:)
        session_id = next_session_id(invocation)
        session_metadata = metadata.merge(namespace: namespace, session_id: session_id)
        effective_invoker =
          if invoker.respond_to?(:with_metadata)
            invoker.with_metadata(session_metadata)
          else
            invoker
          end

        environment.run_collection_session(
          session_id: session_id,
          items: invocation.items,
          compiled_graph: invocation.compiled_graph,
          key: invocation.key_name,
          inputs: invocation.inputs,
          invoker: effective_invoker,
          window: invocation.window,
          operation_name: invocation.operation.name,
          metadata: session_metadata
        )
      end

      private

      attr_reader :environment, :invoker, :namespace, :metadata, :id_generator

      def next_session_id(invocation)
        return id_generator.call(invocation: invocation) if id_generator

        @mutex.synchronize do
          @sequence += 1
          "#{namespace}/#{invocation.operation.name}/#{@sequence}"
        end
      end
    end
  end
end
