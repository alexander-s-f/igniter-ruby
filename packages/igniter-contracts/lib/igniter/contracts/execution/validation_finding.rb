# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      class ValidationFinding
        attr_reader :code, :message, :subjects, :metadata

        def initialize(code:, message:, subjects: [], metadata: {})
          @code = code.to_sym
          @message = message
          @subjects = Array(subjects).map(&:to_sym).freeze
          @metadata = metadata.freeze
          freeze
        end

        def to_h
          {
            code: code,
            message: message,
            subjects: subjects,
            metadata: StructuredDump.dump(metadata)
          }
        end
      end
    end
  end
end
