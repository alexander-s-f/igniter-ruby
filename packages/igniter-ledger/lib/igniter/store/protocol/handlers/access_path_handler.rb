# frozen_string_literal: true

module Igniter
  module Store
    module Protocol
      module Handlers
        class AccessPathHandler
          REQUIRED = %i[name store fields].freeze

          def initialize(store) = @store = store

          def call(descriptor)
            missing = REQUIRED.select { |f| descriptor[f].nil? }
            return Receipt.rejection("Missing required fields: #{missing.join(", ")}", kind: :access_path) if missing.any?

            name       = descriptor[:name].to_sym
            store_name = descriptor[:store].to_sym
            unique     = descriptor.fetch(:unique, true)

            @store.register_path(
              AccessPath.new(
                store:     store_name,
                lookup:    :primary_key,
                scope:     name,
                filters:   {},
                cache_ttl: descriptor[:cache_ttl],
                consumers: []
              )
            )

            warnings = unique ? [] : ["unique: false — non-unique access paths are recorded but not enforced by the engine"]
            Receipt.accepted(kind: :access_path, name: name, warnings: warnings)
          end
        end
      end
    end
  end
end
