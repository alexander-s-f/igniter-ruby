# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Capabilities
        class Declaration
          attr_reader :callable, :capabilities

          def initialize(callable:, capabilities:)
            @callable = callable
            @capabilities = Array(capabilities).flatten.compact.map(&:to_sym).uniq.freeze
            freeze
          end

          def call(**kwargs)
            callable.call(**kwargs)
          end

          def declared_capabilities
            capabilities
          end

          def pure?
            capabilities.include?(:pure)
          end
        end
      end
    end
  end
end
