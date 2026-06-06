# frozen_string_literal: true

require_relative "content_addressing/content_key"
require_relative "content_addressing/cache"
require_relative "content_addressing/declaration"

module Igniter
  module Extensions
    module Contracts
      module ContentAddressingPack
        module_function

        def manifest
          Igniter::Contracts::PackManifest.new(
            name: :extensions_content_addressing,
            metadata: { category: :runtime, capabilities: [:pure] }
          )
        end

        def install_into(kernel)
          kernel
        end

        def cache
          @cache ||= ContentAddressing::Cache.new
        end

        def cache=(value)
          @cache = value
        end

        def reset_cache!
          cache.clear
        end

        def stats
          cache.stats
        end

        def content_key(inputs:, fingerprint: nil, callable: nil)
          resolved_fingerprint =
            if fingerprint
              fingerprint
            elsif callable
              callable.respond_to?(:content_fingerprint) ? callable.content_fingerprint : default_fingerprint_for(callable)
            else
              raise ArgumentError, "content_key requires fingerprint: or callable:"
            end

          ContentAddressing::ContentKey.compute(fingerprint: resolved_fingerprint, inputs: inputs)
        end

        def content_addressed(callable: nil, fingerprint: nil, capabilities: [:pure], cache: self.cache, &block)
          target = callable || block
          raise ArgumentError, "content_addressed requires a callable or block" unless target

          ContentAddressing::Declaration.new(
            callable: target,
            fingerprint: fingerprint || default_fingerprint_for(target),
            cache: cache,
            capabilities: capabilities
          )
        end

        def pure(callable: nil, fingerprint: nil, cache: self.cache, &block)
          content_addressed(
            callable: callable,
            fingerprint: fingerprint,
            capabilities: [:pure],
            cache: cache,
            &block
          )
        end

        def default_fingerprint_for(target)
          if target.respond_to?(:content_fingerprint)
            target.content_fingerprint
          elsif target.is_a?(Proc)
            file, line = target.source_location
            "proc:#{file}:#{line}"
          elsif target.respond_to?(:name) && !target.name.nil?
            target.name
          else
            "anonymous_callable"
          end
        end
      end
    end
  end
end
