# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      class Builder
        def self.build(profile:, &block)
          builder = new(profile: profile)
          builder.instance_eval(&block)
          builder
        end

        attr_reader :profile, :operations

        def initialize(profile:)
          @profile = profile
          @operations = []
        end

        def add_operation(kind:, name:, **attributes)
          normalized_kind = kind.to_sym
          unless profile.supports_node_kind?(normalized_kind)
            raise UnknownNodeKindError,
                  "unknown node kind #{normalized_kind}"
          end

          operations << Operation.new(kind: normalized_kind, name: name, attributes: attributes)
        end

        def method_missing(name, *args, **kwargs, &block)
          keyword = profile.dsl_keyword(name)
          keyword.call(*args, builder: self, **kwargs, &block)
        rescue KeyError
          raise UnknownDslKeywordError, "unknown DSL keyword #{name}"
        end

        def respond_to_missing?(name, include_private = false)
          profile.dsl_keywords.key?(name.to_sym) || super
        end
      end
    end
  end
end
