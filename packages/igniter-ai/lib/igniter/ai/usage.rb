# frozen_string_literal: true

module Igniter
  module AI
    Usage = Struct.new(:input_tokens, :output_tokens, :total_tokens, keyword_init: true) do
      def initialize(input_tokens: nil, output_tokens: nil, total_tokens: nil)
        super(
          input_tokens: normalize(input_tokens),
          output_tokens: normalize(output_tokens),
          total_tokens: normalize(total_tokens)
        )
        freeze
      end

      def to_h
        {
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          total_tokens: total_tokens
        }.compact
      end

      private

      def normalize(value)
        return nil if value.nil?

        Integer(value)
      end
    end
  end
end
