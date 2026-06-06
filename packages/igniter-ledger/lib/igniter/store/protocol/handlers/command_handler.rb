# frozen_string_literal: true

module Igniter
  module Store
    module Protocol
      module Handlers
        # Command descriptors are metadata-only. Ledger records the app-owned
        # mutation contract but never executes application commands.
        class CommandHandler
          REQUIRED = %i[name owner operation].freeze
          OPERATIONS = %i[record_append record_update history_append none].freeze

          def initialize(store) = @store = store

          def call(descriptor)
            missing = REQUIRED.select { |field| descriptor[field].nil? }
            return Receipt.rejection("Missing required fields: #{missing.join(", ")}", kind: :command) if missing.any?

            name = descriptor[:name].to_sym
            owner = descriptor[:owner].to_sym
            operation = descriptor[:operation].to_sym
            unless OPERATIONS.include?(operation)
              return Receipt.rejection("Unsupported command operation: #{operation.inspect}", kind: :command)
            end

            normalized = descriptor.merge(
              name: name,
              owner: owner,
              operation: operation,
              target_shape: token(descriptor[:target_shape] || target_shape_for(operation)),
              boundary: token(descriptor[:boundary] || :app),
              mutation_intent: token(descriptor[:mutation_intent] || operation)
            )

            @store.schema_graph.register_command_descriptor(normalized)
            Receipt.accepted(kind: :command, name: name)
          end

          private

          def target_shape_for(operation)
            case operation
            when :record_append, :record_update
              :store
            when :history_append
              :history
            else
              :none
            end
          end

          def token(value)
            value.nil? || value.is_a?(Symbol) ? value : value.to_sym
          end
        end
      end
    end
  end
end
