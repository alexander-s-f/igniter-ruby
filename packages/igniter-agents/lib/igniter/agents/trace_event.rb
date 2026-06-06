# frozen_string_literal: true

module Igniter
  module Agents
    TraceEvent = Struct.new(:type, :at, :data, keyword_init: true) do
      def initialize(type:, at:, data: {})
        super(
          type: type.to_sym,
          at: at.to_s,
          data: data.transform_keys(&:to_sym).freeze
        )
        freeze
      end

      def to_h
        {
          type: type,
          at: at,
          data: data
        }
      end
    end
  end
end
