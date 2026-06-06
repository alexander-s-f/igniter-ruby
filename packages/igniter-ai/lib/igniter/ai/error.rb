# frozen_string_literal: true

module Igniter
  module AI
    class Error < StandardError
      attr_reader :context

      def initialize(message, context: {})
        super(message)
        @context = context.freeze
      end
    end
  end
end
