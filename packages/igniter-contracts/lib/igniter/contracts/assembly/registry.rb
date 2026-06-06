# frozen_string_literal: true

module Igniter
  module Contracts
    module Assembly
      class Registry
        def initialize(name:)
          @name = name
          @entries = {}
          @frozen = false
        end

        def register(key, value)
          raise FrozenRegistryError, "#{@name} is frozen" if frozen?

          normalized_key = normalize_key(key)
          raise DuplicateRegistrationError, "#{@name} already has #{normalized_key}" if @entries.key?(normalized_key)

          @entries[normalized_key] = value
          value
        end

        def fetch(key)
          @entries.fetch(normalize_key(key))
        end

        def registered?(key)
          @entries.key?(normalize_key(key))
        end

        def entries
          @entries.dup
        end

        def to_h
          entries
        end

        def freeze!
          @frozen = true
          @entries.freeze
          self
        end

        def frozen?
          @frozen
        end

        private

        def normalize_key(key)
          key.to_sym
        end
      end
    end
  end
end
