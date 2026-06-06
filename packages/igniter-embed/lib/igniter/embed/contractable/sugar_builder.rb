# frozen_string_literal: true

module Igniter
  module Embed
    module Contractable
      class SugarBuilder
        attr_reader :configured

        def initialize(config:)
          @config = config
          @configured = false
        end

        def migration(from:, to:)
          mark_configured!
          config.role :migration_candidate
          config.stage :shadowed
          config.primary from
          config.candidate to
          config
        end

        def migrate(from, to:)
          migration(from: from, to: to)
        end

        def observe(callable)
          mark_configured!
          config.role :observed_service
          config.stage :captured
          config.primary callable
          config
        end

        def discover(callable)
          mark_configured!
          config.role :discovery_probe
          config.stage :profiled
          config.primary callable
          config
        end

        def shadow(async: nil, sample: nil)
          mark_configured!
          config.async(async) unless async.nil?
          config.sample(sample) unless sample.nil?
          config
        end

        def capture(**options)
          mark_configured!
          config.metadata(capture: options)
        end

        def use(capability, adapter = nil, **options)
          mark_configured!
          case capability.to_sym
          when :normalizer
            require_adapter!(capability, adapter)
            config.normalize_primary adapter
            config.normalize_candidate adapter
          when :redaction
            config.redact_inputs adapter || redaction_adapter(**options)
            config.redaction_input_policy = if adapter
                                              :custom
                                            elsif options[:only]
                                              :only
                                            else
                                              :except
                                            end
          when :acceptance
            raise SugarError, "use :acceptance requires policy:" unless options.key?(:policy)

            policy = options.fetch(:policy)
            config.accept policy, **options.reject { |key, _value| key == :policy }
          when :store
            require_adapter!(capability, adapter)
            config.store adapter
          when :logging, :reporting, :metrics, :validation
            config.capability capability, explicit_capability_target(capability, adapter, **options)
          else
            raise SugarError, "use :#{capability} is not supported in this implementation slice"
          end
          config
        end

        def on(event, callable = nil, &block)
          mark_configured!
          config.on(event, callable, &block)
        end

        def configured?
          !!configured
        end

        def method_missing(name, ...)
          if config.respond_to?(name)
            mark_configured!
            return config.public_send(name, ...)
          end

          super
        end

        def respond_to_missing?(name, include_private = false)
          config.respond_to?(name, include_private) || super
        end

        private

        attr_reader :config

        def mark_configured!
          @configured = true
        end

        def require_adapter!(capability, adapter)
          return if adapter

          raise SugarError, "use :#{capability} requires an explicit adapter"
        end

        def explicit_capability_target(capability, adapter = nil, contract: nil, callable: nil, target: nil)
          targets = [adapter, contract, callable, target].compact
          raise SugarError, "use :#{capability} requires an explicit target" if targets.empty?
          raise SugarError, "use :#{capability} accepts only one explicit target" if targets.length > 1

          targets.first
        end

        def redaction_adapter(only: nil, except: nil)
          raise SugarError, "use :redaction accepts only one of :only or :except" if only && except
          raise SugarError, "use :redaction requires an adapter, :only, or :except" unless only || except

          keys = Array(only || except).map(&:to_sym)
          lambda do |*args, **kwargs|
            inputs = kwargs.empty? && args.first.respond_to?(:to_h) ? args.first.to_h : kwargs
            normalized = inputs.transform_keys(&:to_sym)
            only ? normalized.slice(*keys) : normalized.reject { |key, _value| keys.include?(key) }
          end
        end
      end
    end
  end
end
