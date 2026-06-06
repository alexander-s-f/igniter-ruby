# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      class NamedValues
        def initialize(values = {})
          normalized_values =
            case values
            when NamedValues
              values.to_h
            when MutableNamedValues
              values.snapshot.to_h
            else
              values
            end

          @values = normalized_values.transform_keys(&:to_sym).freeze
          freeze
        end

        def fetch(name)
          @values.fetch(name.to_sym)
        end

        def [](name)
          @values[name.to_sym]
        end

        def key?(name)
          @values.key?(name.to_sym)
        end

        def keys
          @values.keys
        end

        def length
          @values.length
        end

        def to_h
          @values.to_h { |key, value| [key, StructuredDump.dump(value)] }
        end
      end
    end
  end
end
