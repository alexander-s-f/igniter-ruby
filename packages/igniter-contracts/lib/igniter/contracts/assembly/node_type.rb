# frozen_string_literal: true

module Igniter
  module Contracts
    module Assembly
      NodeType = Struct.new(:kind, :metadata, keyword_init: true) do
        def initialize(kind:, metadata: {})
          normalized_metadata = {
            requires_dsl: true,
            requires_runtime: true
          }.merge(metadata).freeze

          super(kind: kind.to_sym, metadata: normalized_metadata)
        end

        def requires_dsl?
          metadata.fetch(:requires_dsl, true)
        end

        def requires_runtime?
          metadata.fetch(:requires_runtime, true)
        end
      end
    end
  end
end
