# frozen_string_literal: true

require_relative "../embed"

module Igniter
  module Embed
    module Rails
      class << self
        def install(container, reloader: nil, cache: nil)
          container.config.cache = cache unless cache.nil?
          return container unless reloader

          raise RailsIntegrationError, "Rails reloader must respond to #to_prepare" unless reloader.respond_to?(:to_prepare)

          reloader.to_prepare { container.reload! }
          container
        end
      end
    end
  end
end
