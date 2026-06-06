# frozen_string_literal: true

module Igniter
  module Contracts
    module Assembly
      class DslKeyword
        attr_reader :name

        def initialize(name, callable = nil, &block)
          @name = name.to_sym
          @callable = callable || block
          raise ArgumentError, "keyword #{@name} requires a callable" unless @callable
        end

        def call(*args, builder:, **kwargs, &block)
          @callable.call(*args, builder:, **kwargs, &block)
        end
      end
    end
  end
end
