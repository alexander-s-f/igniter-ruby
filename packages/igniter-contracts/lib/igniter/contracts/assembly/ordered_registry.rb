# frozen_string_literal: true

module Igniter
  module Contracts
    module Assembly
      class OrderedRegistry
        Entry = Struct.new(:key, :value, keyword_init: true)

        def initialize(name:)
          @name = name
          @entries = []
          @keys = {}
          @frozen = false
        end

        def register(key, value)
          raise FrozenRegistryError, "#{@name} is frozen" if frozen?

          normalized_key = normalize_key(key)
          raise DuplicateRegistrationError, "#{@name} already has #{normalized_key}" if @keys.key?(normalized_key)

          entry = Entry.new(key: normalized_key, value: value)
          @entries << entry
          @keys[normalized_key] = true
          entry
        end

        def registered?(key)
          @keys.key?(normalize_key(key))
        end

        def entries
          @entries.dup
        end

        def freeze!
          @frozen = true
          @entries.freeze
          @keys.freeze
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
