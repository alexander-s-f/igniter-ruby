# frozen_string_literal: true

module Igniter
  module Store
    module Protocol
      module Handlers
        class RelationHandler
          REQUIRED = %i[name from to].freeze

          def initialize(store) = @store = store

          def call(descriptor)
            missing = REQUIRED.select { |f| descriptor[f].nil? }
            return Receipt.rejection("Missing required fields: #{missing.join(", ")}", kind: :relation) if missing.any?

            name       = descriptor[:name].to_sym
            from_desc  = descriptor[:from]
            to_desc    = descriptor[:to]

            unless from_desc.is_a?(Hash) && from_desc[:store] && from_desc[:key]
              return Receipt.rejection("from: must be { store:, key: }", kind: :relation, name: name)
            end
            unless to_desc.is_a?(Hash) && to_desc[:store] && to_desc[:field]
              return Receipt.rejection("to: must be { store:, field: }", kind: :relation, name: name)
            end

            cardinality = descriptor.fetch(:cardinality, :many)
            warnings    = cardinality == :one ? ["cardinality: :one is informational only; engine always stores as G-Set"] : []

            @store.register_relation(
              name,
              source:    to_desc[:store].to_sym,
              partition: to_desc[:field].to_sym,
              target:    from_desc[:store].to_sym
            )

            Receipt.accepted(kind: :relation, name: name, warnings: warnings)
          end
        end
      end
    end
  end
end
