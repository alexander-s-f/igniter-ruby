# frozen_string_literal: true

require_relative "runtime/deferred_result"

module Igniter
  unless const_defined?(:Executor)
    class Executor
      class << self
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@executor_inputs, executor_inputs.transform_values(&:dup))
          subclass.instance_variable_set(:@executor_metadata, executor_metadata.dup)
        end

        def input(name, required: true, type: nil, **metadata)
          executor_inputs[name.to_sym] = metadata.merge(required: required, type: type).compact
        end

        def executor_inputs
          @executor_inputs ||= {}
        end

        def executor_metadata
          @executor_metadata ||= {}
        end

        def executor_key(value = nil)
          metadata_value(:key, value)
        end

        def label(value = nil)
          metadata_value(:label, value)
        end

        def category(value = nil)
          metadata_value(:category, value)
        end

        def summary(value = nil)
          metadata_value(:summary, value)
        end

        def tags(*values)
          return Array(executor_metadata[:tags]).freeze if values.empty?

          executor_metadata[:tags] = values.flatten.compact.map(&:to_sym).freeze
        end

        def output_schema(value = nil)
          metadata_value(:output_schema, value)
        end

        def call(**dependencies)
          new.call(**dependencies)
        end

        def capabilities(*caps)
          if caps.empty?
            @declared_capabilities ||= []
          else
            existing = @declared_capabilities || []
            @declared_capabilities = (existing + caps.flatten.map(&:to_sym)).uniq.freeze
          end
        end

        def declared_capabilities
          @declared_capabilities || []
        end

        def pure
          capabilities(:pure)
        end

        def pure?
          declared_capabilities.include?(:pure)
        end

        def fingerprint(value = nil)
          return @content_fingerprint || name || "anonymous_executor" if value.nil?

          @content_fingerprint = value.to_s.freeze
        end

        def content_fingerprint
          @content_fingerprint || name || "anonymous_executor"
        end

        private

        def metadata_value(key, value)
          return executor_metadata[key] if value.nil?

          executor_metadata[key] = value
        end
      end

      attr_reader :execution, :contract

      def initialize(execution: nil, contract: nil)
        @execution = execution
        @contract = contract
      end

      def defer(token: nil, payload: {})
        Runtime::DeferredResult.build(token: token, payload: payload)
      end
    end
  end
end
