# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      class StepResult
        attr_reader :value, :failure, :metadata

        def self.success(value, metadata: {})
          new(value: value, failure: nil, metadata: metadata)
        end

        def self.failure(code:, message:, details: {}, metadata: {})
          new(
            value: nil,
            failure: {
              code: code.to_sym,
              message: message,
              details: details
            },
            metadata: metadata
          )
        end

        def initialize(value:, failure:, metadata: {})
          @value = value
          @failure = failure&.transform_keys(&:to_sym)
          @metadata = metadata.transform_keys(&:to_sym).freeze
          freeze
        end

        def success?
          failure.nil?
        end

        def failure?
          !success?
        end

        def to_h
          {
            success: success?,
            value: StructuredDump.dump(value),
            failure: StructuredDump.dump(failure),
            metadata: StructuredDump.dump(metadata)
          }
        end
      end
    end
  end
end
