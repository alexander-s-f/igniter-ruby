# frozen_string_literal: true

module Igniter
  module Application
    class Interface < ServiceDefinition
      def initialize(name:, callable:, metadata: {}, source: :application)
        super(name: name, callable: callable, metadata: metadata, source: source)
      end
    end
  end
end
