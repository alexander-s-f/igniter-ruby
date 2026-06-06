# frozen_string_literal: true

module Igniter
  module LedgerClient
    class Error < StandardError
      attr_reader :response, :request_id

      def initialize(message, response: nil, request_id: nil)
        super(message)
        @response = response
        @request_id = request_id
      end
    end

    class TransportError < Error; end
  end
end
