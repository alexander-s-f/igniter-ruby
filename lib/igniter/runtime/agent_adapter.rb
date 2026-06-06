# frozen_string_literal: true

require "igniter/errors"

module Igniter
  module Runtime
    unless const_defined?(:AgentAdapter, false)
      # Base transport seam for agent nodes.
      #
      # Runtime delegates agent-node delivery to this adapter instead of
      # directly depending on the actor runtime package.
      class AgentAdapter
        def call(node:, inputs:, execution: nil) # rubocop:disable Lint/UnusedMethodArgument
          raise ResolutionError,
                "agent :#{node.name} requires a configured agent adapter. " \
                "Require 'igniter/agent', pass `runner :inline, agent_adapter: ...`, " \
                "or set `Igniter::Runtime.agent_adapter`."
        end

        def cast(node:, inputs:, execution: nil) # rubocop:disable Lint/UnusedMethodArgument
          raise ResolutionError,
                "agent :#{node.name} requires a configured agent adapter. " \
                "Require 'igniter/agent', pass `runner :inline, agent_adapter: ...`, " \
                "or set `Igniter::Runtime.agent_adapter`."
        end

        def continue_session(session:, payload:, execution: nil, trace: nil, token: nil, waiting_on: nil, request: nil, reply: nil, phase: nil) # rubocop:disable Lint/UnusedMethodArgument
          nil
        end

        def resume_session(session:, execution: nil, value: nil) # rubocop:disable Lint/UnusedMethodArgument
          nil
        end
      end
    end

    class << self
      attr_writer :agent_adapter

      def agent_adapter
        @agent_adapter ||= AgentAdapter.new
      end
    end
  end
end
