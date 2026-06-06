# frozen_string_literal: true

module Igniter
  module Embed
    class ContractHandle
      attr_reader :name, :container

      def initialize(name:, container:)
        @name = name.to_sym
        @container = container
        freeze
      end

      def compile
        container.compile(name)
      end

      def call(inputs = {}, **keyword_inputs)
        container.call(name, inputs.merge(keyword_inputs))
      end
    end
  end
end
