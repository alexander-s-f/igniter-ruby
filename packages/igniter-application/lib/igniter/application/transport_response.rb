# frozen_string_literal: true

module Igniter
  module Application
    class TransportResponse
      attr_reader :result, :metadata

      def initialize(result:, metadata: {})
        @result = result
        @metadata = metadata.dup.freeze
        freeze
      end

      def to_h
        {
          result: result.respond_to?(:to_h) ? result.to_h : result,
          metadata: metadata.dup
        }
      end
    end
  end
end
