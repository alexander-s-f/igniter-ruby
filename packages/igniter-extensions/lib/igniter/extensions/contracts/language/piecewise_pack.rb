# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Language
        module PiecewisePack
          UNSET = Object.new.freeze

          module_function

          def manifest
            Igniter::Contracts::PackManifest.new(
              name: :extensions_language_piecewise,
              registry_contracts: [Igniter::Contracts::PackManifest.dsl_keyword(:piecewise)]
            )
          end

          def install_into(kernel)
            kernel.dsl_keywords.register(:piecewise, piecewise_keyword)
            kernel
          end

          def piecewise_keyword
            Igniter::Contracts::DslKeyword.new(:piecewise) do |name, on:, builder:, depends_on: [], decision: nil, &block|
              raise ArgumentError, "piecewise :#{name} requires a block" unless block

              selector_name = on.to_sym
              decision_name = (decision || :"#{name}_decision").to_sym
              dependency_names = [selector_name, *Array(depends_on).map(&:to_sym)].uniq
              definition = Definition.new(name: name, selector_name: selector_name)
              definition.instance_eval(&block)
              definition.validate!

              builder.add_operation(
                kind: :compute,
                name: decision_name,
                depends_on: dependency_names,
                callable: lambda do |**values|
                  definition.resolve(values)
                end
              )
              builder.add_operation(
                kind: :compute,
                name: name,
                depends_on: [decision_name],
                callable: lambda do |**values|
                  values.fetch(decision_name).fetch(:value)
                end
              )
            end
          end

          def invoke_value(callable_or_value, kwargs)
            return callable_or_value unless callable_or_value.respond_to?(:call)

            parameters = callable_or_value.parameters
            accepts_any_keywords = parameters.any? { |kind, _name| kind == :keyrest }
            return callable_or_value.call(**kwargs) if accepts_any_keywords

            accepted = parameters.select { |kind, _name| %i[key keyreq].include?(kind) }.map(&:last)
            callable_or_value.call(**kwargs.slice(*accepted))
          end

          class Definition
            def initialize(name:, selector_name:)
              @name = name.to_sym
              @selector_name = selector_name.to_sym
              @cases = []
              @default_case = nil
            end

            def eq(match, id: nil, value: UNSET, &block)
              add_case(:eq, match, id: id, value: value, block: block)
            end

            def between(range, id: nil, value: UNSET, &block)
              raise ArgumentError, "piecewise :#{@name} between requires a Range" unless range.is_a?(Range)

              add_case(:between, range, id: id, value: value, block: block)
            end

            def in(values, id: nil, value: UNSET, &block)
              array = Array(values)
              raise ArgumentError, "piecewise :#{@name} in requires a non-empty list" if array.empty?

              add_case(:in, array.freeze, id: id, value: value, block: block)
            end

            def matches(pattern, id: nil, value: UNSET, &block)
              raise ArgumentError, "piecewise :#{@name} matches requires a Regexp" unless pattern.is_a?(Regexp)

              add_case(:matches, pattern, id: id, value: value, block: block)
            end

            def default(id: :default, value: UNSET, &block)
              raise ArgumentError, "piecewise :#{@name} can define only one default" if @default_case

              @default_case = case_payload(:default, :default, id: id, value: value, block: block)
            end

            def validate!
              raise ArgumentError, "piecewise :#{@name} requires at least one case" if @cases.empty?
              raise ArgumentError, "piecewise :#{@name} requires a default case" unless @default_case

              duplicate_ids = (@cases.map { |entry| entry.fetch(:id) } + [@default_case.fetch(:id)])
                              .group_by { |id| id }
                              .select { |_id, group| group.length > 1 }
                              .keys
              return if duplicate_ids.empty?

              raise ArgumentError, "piecewise :#{@name} has duplicate case ids: #{duplicate_ids.join(", ")}"
            end

            def resolve(kwargs)
              selector_value = kwargs.fetch(@selector_name)
              selected = @cases.find { |entry| match?(entry, selector_value) } || @default_case

              {
                case: selected.fetch(:id),
                value: PiecewisePack.invoke_value(selected.fetch(:value), kwargs),
                matcher: selected.fetch(:matcher),
                matched_on: selected.fetch(:match),
                selector: @selector_name,
                selector_value: selector_value
              }
            end

            private

            def add_case(matcher, match, id:, value:, block:)
              @cases << case_payload(matcher, match, id: id || :"case_#{@cases.length + 1}", value: value, block: block)
            end

            def case_payload(matcher, match, id:, value:, block:)
              raise ArgumentError, "piecewise :#{@name} case cannot combine value: with a block" if !value.equal?(UNSET) && block
              raise ArgumentError, "piecewise :#{@name} case requires value: or a block" if value.equal?(UNSET) && !block

              {
                id: id.to_sym,
                matcher: matcher,
                match: match,
                value: block || value
              }
            end

            def match?(entry, selector_value)
              case entry.fetch(:matcher)
              when :eq
                selector_value == entry.fetch(:match)
              when :between
                entry.fetch(:match).cover?(selector_value)
              when :in
                entry.fetch(:match).include?(selector_value)
              when :matches
                !!(selector_value.to_s =~ entry.fetch(:match))
              else
                false
              end
            end
          end
        end
      end
    end
  end
end
