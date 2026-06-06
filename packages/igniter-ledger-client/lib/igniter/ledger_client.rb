# frozen_string_literal: true

require_relative "ledger_client/envelope"
require_relative "ledger_client/error"
require_relative "ledger_client/results"
require_relative "ledger_client/subscription"
require_relative "ledger_client/client"
require_relative "ledger_client/transports/object_dispatch"
require_relative "ledger_client/transports/remote_http"

module Igniter
  module LedgerClient
    def self.wrap(target)
      return target if target.is_a?(Client)

      Client.new(transport: Transports::ObjectDispatch.new(target))
    end

    def self.remote_http(endpoint, **options)
      Client.new(transport: Transports::RemoteHTTP.new(endpoint, **options))
    end
  end
end
