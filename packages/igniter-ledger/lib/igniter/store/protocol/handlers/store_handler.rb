# frozen_string_literal: true

module Igniter
  module Store
    module Protocol
      module Handlers
        class StoreHandler
          REQUIRED = %i[name key].freeze

          def initialize(store) = @store = store

          def call(descriptor)
            missing = REQUIRED.select { |f| descriptor[f].nil? }
            return Receipt.rejection("Missing required fields: #{missing.join(", ")}", kind: :store) if missing.any?

            name = descriptor[:name].to_sym
            @store.schema_graph.register_store_descriptor(descriptor.merge(name: name))
            Receipt.accepted(kind: :store, name: name)
          end
        end
      end
    end
  end
end
