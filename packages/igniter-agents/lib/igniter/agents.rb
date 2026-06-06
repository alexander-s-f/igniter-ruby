# frozen_string_literal: true

require "securerandom"
require "time"

require "igniter-ai"

require_relative "agents/agent_definition"
require_relative "agents/agent_run"
require_relative "agents/agent_turn"
require_relative "agents/runner"
require_relative "agents/tool_call"
require_relative "agents/trace_event"

module Igniter
  module Agents
    class << self
      def agent(...)
        AgentDefinition.new(...)
      end

      def run(definition, ai_client:, input:, context: {}, metadata: {}, id: nil, clock: Time)
        Runner.new(ai_client: ai_client, clock: clock).run(
          definition,
          input: input,
          context: context,
          metadata: metadata,
          id: id
        )
      end
    end
  end
end
