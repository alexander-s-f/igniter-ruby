# frozen_string_literal: true

module Igniter
  module Store
    module Protocol
      module Handlers
        class HistoryHandler
          REQUIRED = %i[name key].freeze

          def initialize(store) = @store = store

          def call(descriptor)
            missing = REQUIRED.select { |f| descriptor[f].nil? }
            return Receipt.rejection("Missing required fields: #{missing.join(", ")}", kind: :history) if missing.any?

            name = descriptor[:name].to_sym
            @store.schema_graph.register_history_descriptor(descriptor.merge(name: name))
            Receipt.accepted(kind: :history, name: name)
          end
        end
      end
    end
  end
end
