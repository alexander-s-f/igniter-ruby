# frozen_string_literal: true

require_relative "errors"
require_relative "executor"

module Igniter
  unless const_defined?(:Tool)
    class Tool < Executor
      class CapabilityError < Igniter::Error; end

      require_relative "tool/discoverable"
      include Discoverable

      def self.inherited(subclass)
        super
        subclass.instance_variable_set(:@tool_params, [])
        subclass.instance_variable_set(:@required_capabilities, [].freeze)
        subclass.instance_variable_set(:@tool_description, @tool_description)
      end
    end
  end
end
