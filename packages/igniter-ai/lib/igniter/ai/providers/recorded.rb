# frozen_string_literal: true

module Igniter
  module AI
    module Providers
      class Recorded
        def initialize(records:)
          @records = records.map { |record| record.transform_keys(&:to_sym).freeze }.freeze
          @index = 0
        end

        def complete(request)
          record = @records.fetch(@index) do
            return ModelResponse.new(
              text: nil,
              metadata: { provider: :recorded, model: request.model },
              error: :recording_exhausted
            )
          end
          @index += 1

          ModelResponse.new(
            text: record[:text],
            usage: usage_from(record[:usage]),
            metadata: (record[:metadata] || {}).merge(provider: :recorded, model: request.model),
            error: record[:error]
          )
        end

        private

        def usage_from(payload)
          return Usage.new if payload.nil?

          Usage.new(**payload.transform_keys(&:to_sym))
        end
      end
    end
  end
end
