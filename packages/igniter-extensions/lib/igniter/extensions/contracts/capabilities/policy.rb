# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Capabilities
        class Policy
          attr_reader :denied, :required, :on_undeclared

          def initialize(denied: [], required: [], on_undeclared: :ignore)
            @denied = Array(denied).map(&:to_sym).uniq.freeze
            @required = Array(required).map(&:to_sym).uniq.freeze
            @on_undeclared = on_undeclared.to_sym
            freeze
          end
        end
      end
    end
  end
end
