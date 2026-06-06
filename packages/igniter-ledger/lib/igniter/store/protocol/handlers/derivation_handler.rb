# frozen_string_literal: true

module Igniter
  module Store
    module Protocol
      module Handlers
        # Derivation descriptors are metadata-only in OP1.
        # Execution requires a rule callable which external descriptor packets cannot carry.
        # The descriptor is stored in the schema graph for OP2 introspection.
        class DerivationHandler
          REQUIRED = %i[name inputs output].freeze

          def initialize(store) = @store = store

          def call(descriptor)
            missing = REQUIRED.select { |f| descriptor[f].nil? }
            return Receipt.rejection("Missing required fields: #{missing.join(", ")}", kind: :derivation) if missing.any?

            name = descriptor[:name].to_sym
            warnings = ["derivation: #{name.inspect} registered as metadata only; attach a rule callable via register_derivation to enable execution"]
            Receipt.accepted(kind: :derivation, name: name, warnings: warnings)
          end
        end
      end
    end
  end
end
