# frozen_string_literal: true

module Igniter
  module AI
    ModelRequest = Struct.new(:model, :instructions, :input, :metadata, :options, keyword_init: true) do
      def initialize(model:, input:, instructions: nil, metadata: {}, options: {})
        super(
          model: model.to_s,
          instructions: instructions&.to_s,
          input: input.to_s,
          metadata: metadata.transform_keys(&:to_sym).freeze,
          options: options.transform_keys(&:to_sym).freeze
        )
        freeze
      end

      def to_h
        {
          model: model,
          instructions: instructions,
          input: input,
          metadata: metadata,
          options: options
        }.compact
      end
    end
  end
end
