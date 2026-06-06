# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Capabilities
        class Violation
          attr_reader :kind, :node_name, :capabilities, :message

          def initialize(kind:, node_name:, capabilities:, message:)
            @kind = kind.to_sym
            @node_name = node_name.to_sym
            @capabilities = Array(capabilities).map(&:to_sym).freeze
            @message = message.to_s
            freeze
          end

          def to_h
            {
              kind: kind,
              node_name: node_name,
              capabilities: capabilities,
              message: message
            }
          end
        end
      end
    end
  end
end
