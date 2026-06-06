# frozen_string_literal: true

module Igniter
  module Agents
    AgentRun = Struct.new(
      :id, :agent_name, :status, :input, :context, :turns, :trace, :metadata, :error,
      keyword_init: true
    ) do
      def initialize(id:, agent_name:, status:, input:, context: {}, turns: [], trace: [], metadata: {}, error: nil)
        super(
          id: id.to_s,
          agent_name: agent_name.to_sym,
          status: status.to_sym,
          input: input.to_s,
          context: context.transform_keys(&:to_sym).freeze,
          turns: turns.freeze,
          trace: trace.freeze,
          metadata: metadata.transform_keys(&:to_sym).freeze,
          error: error
        )
        freeze
      end

      def success?
        status == :succeeded
      end

      def failed?
        status == :failed
      end

      def to_h
        {
          id: id,
          agent_name: agent_name,
          status: status,
          input: input,
          context: context,
          turns: turns.map(&:to_h),
          trace: trace.map(&:to_h),
          metadata: metadata,
          error: error
        }
      end
    end
  end
end
