# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Igniter
  module AI
    module Providers
      class OpenAIResponses
        ENDPOINT = URI("https://api.openai.com/v1/responses")

        def initialize(api_key:, model: nil, endpoint: ENDPOINT, transport: nil)
          @api_key = api_key.to_s
          @model = model&.to_s
          @endpoint = endpoint
          @transport = transport
        end

        def complete(request)
          payload = request_payload(request)
          status, body = perform(payload)

          unless status.between?(200, 299)
            return ModelResponse.new(
              text: nil,
              metadata: { provider: :openai, model: payload.fetch(:model), status: status },
              error: "openai_http_#{status}"
            )
          end

          parsed = JSON.parse(body)
          text = output_text(parsed)
          ModelResponse.new(
            text: text,
            usage: usage_from(parsed["usage"]),
            metadata: { provider: :openai, model: payload.fetch(:model), id: parsed["id"] }.compact,
            error: text.to_s.strip.empty? ? :openai_empty_response : nil
          )
        rescue StandardError => e
          ModelResponse.new(
            text: nil,
            metadata: { provider: :openai, model: @model || request.model },
            error: e.class.name
          )
        end

        private

        def request_payload(request)
          options = request.options.dup
          store = options.key?(:store) ? options.delete(:store) : false
          {
            model: @model || request.model,
            store: store,
            instructions: request.instructions,
            input: request.input
          }.compact.merge(options)
        end

        def perform(payload)
          return @transport.call(payload) if @transport

          response = Net::HTTP.start(@endpoint.host, @endpoint.port, use_ssl: @endpoint.scheme == "https") do |http|
            http.request(http_request(payload))
          end

          [Integer(response.code), response.body.to_s]
        end

        def http_request(payload)
          request = Net::HTTP::Post.new(@endpoint)
          request["authorization"] = "Bearer #{@api_key}"
          request["content-type"] = "application/json"
          request.body = JSON.generate(payload)
          request
        end

        def output_text(payload)
          direct = payload["output_text"]
          return direct if direct.is_a?(String)

          Array(payload["output"]).flat_map do |item|
            Array(item["content"]).filter_map { |content| content["text"] }
          end.join("\n")
        end

        def usage_from(payload)
          return Usage.new unless payload.is_a?(Hash)

          Usage.new(
            input_tokens: payload["input_tokens"],
            output_tokens: payload["output_tokens"],
            total_tokens: payload["total_tokens"]
          )
        end
      end
    end
  end
end
