# frozen_string_literal: true

module Igniter
  module AI
    module Providers
      class Fake
        def initialize(text: "Fake AI response.", error: nil, metadata: {})
          @text = text
          @error = error
          @metadata = metadata
        end

        def complete(request)
          ModelResponse.new(
            text: @text,
            usage: Usage.new(input_tokens: request.input.length, output_tokens: @text.to_s.length),
            metadata: @metadata.merge(provider: :fake, model: request.model),
            error: @error
          )
        end
      end
    end
  end
end
