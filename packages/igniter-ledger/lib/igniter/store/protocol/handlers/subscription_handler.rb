# frozen_string_literal: true

module Igniter
  module Store
    module Protocol
      module Handlers
        class SubscriptionHandler
          REQUIRED = %i[name source].freeze

          def initialize(store) = @store = store

          def call(descriptor)
            missing = REQUIRED.select { |f| descriptor[f].nil? }
            return Receipt.rejection("Missing required fields: #{missing.join(", ")}", kind: :subscription) if missing.any?

            name = descriptor[:name].to_sym
            @store.schema_graph.register_subscription_descriptor(descriptor.merge(name: name))
            Receipt.accepted(kind: :subscription, name: name)
          end
        end
      end
    end
  end
end
