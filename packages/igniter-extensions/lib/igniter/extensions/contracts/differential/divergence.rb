# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Differential
        class Divergence
          attr_reader :output_name, :primary_value, :candidate_value, :kind

          def initialize(output_name:, primary_value:, candidate_value:, kind:)
            @output_name = output_name.to_sym
            @primary_value = primary_value
            @candidate_value = candidate_value
            @kind = kind.to_sym
            freeze
          end

          def delta
            return nil unless primary_value.is_a?(Numeric) && candidate_value.is_a?(Numeric)

            candidate_value - primary_value
          end

          def to_h
            {
              output_name: output_name,
              primary_value: primary_value,
              candidate_value: candidate_value,
              kind: kind,
              delta: delta
            }
          end
        end
      end
    end
  end
end
