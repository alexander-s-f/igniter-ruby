# frozen_string_literal: true

require_relative "ai/error"
require_relative "ai/usage"
require_relative "ai/model_request"
require_relative "ai/model_response"
require_relative "ai/client"
require_relative "ai/providers/fake"
require_relative "ai/providers/recorded"
require_relative "ai/providers/openai_responses"

module Igniter
  module AI
    class << self
      def client(provider:)
        Client.new(provider: provider)
      end

      def request(...)
        ModelRequest.new(...)
      end

      def response(...)
        ModelResponse.new(...)
      end
    end
  end
end
