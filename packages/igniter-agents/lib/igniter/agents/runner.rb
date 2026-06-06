# frozen_string_literal: true

module Igniter
  module Agents
    class Runner
      attr_reader :ai_client, :clock

      def initialize(ai_client:, clock: Time)
        @ai_client = ai_client
        @clock = clock
      end

      def run(definition, input:, context: {}, metadata: {}, id: nil)
        run_id = id || "agent-run-#{SecureRandom.hex(8)}"
        started_at = timestamp
        request = Igniter::AI.request(
          model: definition.model,
          instructions: definition.instructions,
          input: input,
          metadata: metadata.merge(agent: definition.name, run_id: run_id)
        )
        response = ai_client.complete(request)
        finished_at = timestamp

        AgentRun.new(
          id: run_id,
          agent_name: definition.name,
          status: response.success? ? :succeeded : :failed,
          input: input,
          context: context,
          turns: [AgentTurn.new(index: 0, request: request, response: response)],
          trace: trace_for(started_at, finished_at, response),
          metadata: metadata.merge(started_at: started_at, finished_at: finished_at),
          error: response.error
        )
      end

      private

      def trace_for(started_at, finished_at, response)
        [
          TraceEvent.new(type: :agent_started, at: started_at),
          TraceEvent.new(
            type: response.success? ? :agent_succeeded : :agent_failed,
            at: finished_at,
            data: { error: response.error }.compact
          )
        ]
      end

      def timestamp
        clock.now.utc.iso8601
      end
    end
  end
end
