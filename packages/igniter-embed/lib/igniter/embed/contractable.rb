# frozen_string_literal: true

require_relative "contractable/acceptance"
require_relative "contractable/adapters"
require_relative "contractable/config"
require_relative "contractable/sugar_builder"
require_relative "contractable/runner"

module Igniter
  module Embed
    module Contractable
      module_function

      def build(name, &block)
        config = Config.new(name: name)
        evaluate_block(config, &block) if block
        Runner.new(config: config)
      end

      def evaluate_block(config, &block)
        if block.arity.zero?
          SugarBuilder.new(config: config).instance_eval(&block)
        else
          block.call(config)
        end
      end
    end
  end
end
