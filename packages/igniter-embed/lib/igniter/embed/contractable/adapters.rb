# frozen_string_literal: true

module Igniter
  module Embed
    module Contractable
      module Adapters
        class InlineAsync
          def enqueue(name:, inputs:, metadata:, handoff: nil, &block) # rubocop:disable Lint/UnusedMethodArgument
            block.call
          end
        end

        class ThreadAsync
          def enqueue(name:, inputs:, metadata:, handoff: nil, &block) # rubocop:disable Lint/UnusedMethodArgument
            Thread.new { block.call }
          end
        end

        class MemoryStore
          attr_reader :observations

          def initialize
            @observations = []
          end

          def record(observation)
            observations << observation
          end
        end
      end
    end
  end
end
