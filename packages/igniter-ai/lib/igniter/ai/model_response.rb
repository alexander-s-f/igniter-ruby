# frozen_string_literal: true

module Igniter
  module AI
    ModelResponse = Struct.new(:text, :usage, :metadata, :error, keyword_init: true) do
      def initialize(text: nil, usage: nil, metadata: {}, error: nil)
        super(
          text: text,
          usage: usage || Usage.new,
          metadata: metadata.transform_keys(&:to_sym).freeze,
          error: error
        )
        freeze
      end

      def success?
        error.nil? && !text.to_s.strip.empty?
      end

      def to_h
        {
          success: success?,
          text: text,
          usage: usage.to_h,
          metadata: metadata,
          error: error
        }
      end
    end
  end
end
