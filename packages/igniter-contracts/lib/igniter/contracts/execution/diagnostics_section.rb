# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      class DiagnosticsSection
        attr_reader :name, :value

        def initialize(name:, value:)
          @name = name.to_sym
          @value = normalize_value(value)
          freeze
        end

        def to_h
          {
            name: name,
            value: StructuredDump.dump(value)
          }
        end

        private

        def normalize_value(value)
          case value
          when NamedValues
            value
          when Hash
            NamedValues.new(value)
          else
            value
          end
        end
      end
    end
  end
end
