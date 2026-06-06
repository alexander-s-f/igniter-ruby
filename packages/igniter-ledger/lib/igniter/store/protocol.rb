# frozen_string_literal: true

require_relative "protocol/receipt"
require_relative "protocol/handlers/store_handler"
require_relative "protocol/handlers/history_handler"
require_relative "protocol/handlers/access_path_handler"
require_relative "protocol/handlers/relation_handler"
require_relative "protocol/handlers/projection_handler"
require_relative "protocol/handlers/derivation_handler"
require_relative "protocol/handlers/command_handler"
require_relative "protocol/handlers/effect_handler"
require_relative "protocol/handlers/subscription_handler"
require_relative "protocol/interpreter"
require_relative "protocol/sync_profile"
require_relative "protocol/wire_envelope"

module Igniter
  module Store
    module Protocol
      # Convenience factory: Protocol.new returns a fresh Interpreter backed by
      # an in-memory IgniterStore.  Pass an existing store to wrap it instead.
      def self.new(store = nil)
        Interpreter.new(store || IgniterStore.new)
      end
    end
  end
end
