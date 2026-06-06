# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module BranchPack
        UNSET = Object.new.freeze

        class << self
          def manifest
            Igniter::Contracts::PackManifest.new(
              name: :extensions_branch,
              registry_contracts: [Igniter::Contracts::PackManifest.dsl_keyword(:branch)]
            )
          end

          def install_into(kernel)
            kernel.dsl_keywords.register(:branch, branch_keyword)
            kernel
          end

          def branch_keyword
            Igniter::Contracts::DslKeyword.new(:branch) do |name, on:, builder:, depends_on: [], &block|
              raise ArgumentError, "branch :#{name} requires a block" unless block

              selector_name = on.to_sym
              dependency_names = [selector_name, *Array(depends_on).map(&:to_sym)].uniq
              definition = Definition.new(name: name, selector_name: selector_name)
              definition.instance_eval(&block)
              definition.validate!

              builder.add_operation(
                kind: :compute,
                name: name,
                depends_on: dependency_names,
                callable: lambda do |**values|
                  definition.resolve(values)
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

            def on(match = UNSET, id: nil, value: UNSET, **options, &block)
              matcher_kind, matcher_value = normalize_match(match, options)
              resolved_value = normalize_value(value, block)

              @cases << {
                id: (id || :"case_#{@cases.length + 1}").to_sym,
                matcher: matcher_kind,
                match: matcher_value,
                value: resolved_value
              }
            end

            def default(id: :default, value: UNSET, &block)
              raise ArgumentError, "branch :#{@name} can define only one default" if @default_case

              @default_case = {
                id: id.to_sym,
                matcher: :default,
                match: :default,
                value: normalize_value(value, block)
              }
            end

            def validate!
              raise ArgumentError, "branch :#{@name} requires at least one on clause" if @cases.empty?
              raise ArgumentError, "branch :#{@name} requires a default clause" unless @default_case

              duplicate_ids = (@cases.map { |entry| entry.fetch(:id) } + [@default_case.fetch(:id)])
                              .group_by { |id| id }
                              .select { |_id, group| group.length > 1 }
                              .keys
              unless duplicate_ids.empty?
                raise ArgumentError,
                      "branch :#{@name} has duplicate case ids: #{duplicate_ids.join(", ")}"
              end

              overlapping = overlapping_literals
              return if overlapping.empty?

              raise ArgumentError,
                    "branch :#{@name} has overlapping literal matches: #{overlapping.map(&:inspect).join(", ")}"
            end

            def resolve(kwargs)
              selector_value = kwargs.fetch(@selector_name)
              selected = @cases.find { |entry| match?(entry, selector_value) } || @default_case

              {
                case: selected.fetch(:id),
                value: BranchPack.invoke_value(selected.fetch(:value), kwargs),
                matcher: selected.fetch(:matcher),
                matched_on: selected.fetch(:match),
                selector: @selector_name,
                selector_value: selector_value
              }
            end

            private

            def normalize_match(match, options)
              matcher_options = options.slice(:eq, :in, :matches)
              provided = matcher_options.reject { |_key, value| value.equal?(UNSET) || value.nil? }

              raise ArgumentError, "branch :#{@name} on cannot combine positional match with eq:, in:, or matches:" if !match.equal?(UNSET) && !provided.empty?

              raise ArgumentError, "branch :#{@name} on requires a positional match or one of eq:, in:, or matches:" if match.equal?(UNSET) && provided.empty?

              if provided.length > 1
                raise ArgumentError,
                      "branch :#{@name} on supports only one matcher option at a time"
              end

              return [:eq, match] unless match.equal?(UNSET)

              matcher_kind, matcher_value = provided.first

              case matcher_kind
              when :eq
                [:eq, matcher_value]
              when :in
                array = Array(matcher_value)
                raise ArgumentError, "branch :#{@name} in: requires a non-empty array" if array.empty?

                [:in, array.freeze]
              when :matches
                raise ArgumentError, "branch :#{@name} matches: requires a Regexp" unless matcher_value.is_a?(Regexp)

                [:matches, matcher_value]
              else
                raise ArgumentError, "branch :#{@name} received an unknown matcher #{matcher_kind.inspect}"
              end
            end

            def normalize_value(value, block)
              if !value.equal?(UNSET) && block
                raise ArgumentError,
                      "branch :#{@name} case cannot combine value: with a block"
              end
              raise ArgumentError, "branch :#{@name} case requires value: or a block" if value.equal?(UNSET) && !block

              block || value
            end

            def overlapping_literals
              literals = @cases.flat_map do |entry|
                case entry.fetch(:matcher)
                when :eq
                  [entry.fetch(:match)]
                when :in
                  entry.fetch(:match)
                else
                  []
                end
              end

              literals.group_by { |value| value }
                      .select { |_value, group| group.length > 1 }
                      .keys
            end

            def match?(entry, selector_value)
              case entry.fetch(:matcher)
              when :eq
                selector_value == entry.fetch(:match)
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
