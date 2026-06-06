# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Invariants
        class Violation
          attr_reader :name, :outputs, :error

          def initialize(name:, outputs:, error: nil)
            @name = name.to_sym
            @outputs = outputs.transform_keys(&:to_sym).freeze
            @error = error
            freeze
          end

          def passed?
            false
          end

          def failed?
            true
          end

          def to_h
            {
              name: name,
              outputs: outputs,
              error: error && {
                type: error.class.name,
                message: error.message
              }
            }
          end
        end
      end
    end
  end
end
