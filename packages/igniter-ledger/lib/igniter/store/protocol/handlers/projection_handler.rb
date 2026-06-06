# frozen_string_literal: true

module Igniter
  module Store
    module Protocol
      module Handlers
        class ProjectionHandler
          def initialize(store) = @store = store

          def call(descriptor)
            return Receipt.rejection("Missing required fields: name", kind: :projection) if descriptor[:name].nil?
            if descriptor[:reads].nil? && descriptor[:source].nil?
              return Receipt.rejection("Missing required fields: reads or source", kind: :projection)
            end

            name    = descriptor[:name].to_sym
            source  = descriptor[:source]
            reads   = descriptor[:reads] || source
            reads   = Array(reads).map(&:to_sym)
            relations = Array(descriptor[:relations]).map(&:to_sym)
            consumer_hint = (descriptor[:consumer_hint] || :protocol_client).to_sym
            mode    = descriptor.fetch(:mode, :on_demand)
            reactive = descriptor.key?(:reactive) ? !!descriptor[:reactive] : mode == :materialized

            @store.register_projection(
              ProjectionPath.new(
                name:          name,
                reads:         reads,
                relations:     relations,
                consumer_hint: consumer_hint,
                reactive:      reactive
              )
            )

            Receipt.accepted(kind: :projection, name: name)
          end
        end
      end
    end
  end
end
