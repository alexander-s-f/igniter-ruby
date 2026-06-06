# frozen_string_literal: true

module Igniter
  module Embed
    class HostBuilder
      def initialize(config:)
        @config = config
      end

      def owner(value)
        config.owner(value)
      end

      def path(value)
        config.path(value)
      end

      def root(value)
        config.root(value)
      end

      def cache(value)
        config.cache = value
      end

      def contract(definition, as: nil)
        config.contract(definition, as: as)
      end

      def contracts(&block)
        config.contracts(&block)
      end

      private

      attr_reader :config
    end
  end
end
