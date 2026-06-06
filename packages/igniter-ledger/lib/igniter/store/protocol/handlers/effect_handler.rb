# frozen_string_literal: true

module Igniter
  module Store
    module Protocol
      module Handlers
        # Effect descriptors describe the app-boundary persistence intent that a
        # command lowers to. They are metadata-only and do not execute effects.
        class EffectHandler
          REQUIRED = %i[name owner store_op write_kind].freeze
          STORE_OPS = %i[store_write store_append none].freeze
          WRITE_KINDS = %i[insert update append none].freeze

          def initialize(store) = @store = store

          def call(descriptor)
            missing = REQUIRED.select { |field| descriptor[field].nil? }
            return Receipt.rejection("Missing required fields: #{missing.join(", ")}", kind: :effect) if missing.any?

            name = descriptor[:name].to_sym
            owner = descriptor[:owner].to_sym
            store_op = descriptor[:store_op].to_sym
            write_kind = descriptor[:write_kind].to_sym
            unless STORE_OPS.include?(store_op)
              return Receipt.rejection("Unsupported effect store_op: #{store_op.inspect}", kind: :effect)
            end
            unless WRITE_KINDS.include?(write_kind)
              return Receipt.rejection("Unsupported effect write_kind: #{write_kind.inspect}", kind: :effect)
            end

            normalized = descriptor.merge(
              name: name,
              owner: owner,
              store_op: store_op,
              write_kind: write_kind,
              lowers_to: token(descriptor[:lowers_to] || lowers_to_for(store_op)),
              boundary: token(descriptor[:boundary] || :app)
            )
            normalized[:source_operation] = token(descriptor[:source_operation]) if descriptor.key?(:source_operation)

            @store.schema_graph.register_effect_descriptor(normalized)
            Receipt.accepted(kind: :effect, name: name)
          end

          private

          def lowers_to_for(store_op)
            case store_op
            when :store_write
              :store_t
            when :store_append
              :history_t
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
