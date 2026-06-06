# frozen_string_literal: true

require_relative "errors"
require_relative "executor"

module Igniter
  unless const_defined?(:Effect)
    class Effect < Executor
      class << self
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@effect_type, @effect_type)
          subclass.instance_variable_set(:@idempotent, @idempotent || false)
          subclass.instance_variable_set(:@_built_in_compensation, @_built_in_compensation)
        end

        def effect_type(value = nil)
          return @effect_type || :generic if value.nil?

          @effect_type = value.to_sym
        end

        def idempotent(value = true) # rubocop:disable Style/OptionalBooleanParameter
          @idempotent = value
        end

        def idempotent?
          @idempotent || false
        end

        def compensate(&block)
          raise ArgumentError, "Effect.compensate requires a block" unless block

          @_built_in_compensation = block
        end

        def built_in_compensation
          @_built_in_compensation
        end
      end
    end
  end
end
