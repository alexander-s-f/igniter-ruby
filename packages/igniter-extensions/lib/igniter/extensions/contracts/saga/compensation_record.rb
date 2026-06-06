# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Saga
        class CompensationRecord
          attr_reader :node_name, :error

          def initialize(node_name:, success:, error: nil)
            @node_name = node_name.to_sym
            @success = success
            @error = error
            freeze
          end

          def success?
            @success
          end

          def failed?
            !success?
          end
        end
      end
    end
  end
end
