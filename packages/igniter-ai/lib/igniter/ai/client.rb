# frozen_string_literal: true

module Igniter
  module AI
    class Client
      attr_reader :provider

      def initialize(provider:)
        @provider = provider
      end

      def complete(request = nil, **attributes)
        model_request = request || ModelRequest.new(**attributes)
        provider.complete(model_request)
      end
    end
  end
end
