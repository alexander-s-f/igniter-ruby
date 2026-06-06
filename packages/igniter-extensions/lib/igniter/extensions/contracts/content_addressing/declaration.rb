# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module ContentAddressing
        class Declaration
          attr_reader :callable, :fingerprint, :cache, :capabilities

          def initialize(callable:, fingerprint:, cache:, capabilities:)
            @callable = callable
            @fingerprint = fingerprint.to_s.freeze
            @cache = cache
            @capabilities = Array(capabilities).map(&:to_sym).uniq.freeze
            freeze
          end

          def call(**kwargs)
            key = content_key(kwargs)
            cached = cache.fetch(key)
            return cached unless cached.nil?

            value = callable.call(**kwargs)
            cache.store(key, value)
            value
          end

          def declared_capabilities
            capabilities
          end

          def pure?
            capabilities.include?(:pure)
          end

          def content_fingerprint
            fingerprint
          end

          def content_key(inputs)
            ContentKey.compute(fingerprint: fingerprint, inputs: inputs)
          end
        end
      end
    end
  end
end
