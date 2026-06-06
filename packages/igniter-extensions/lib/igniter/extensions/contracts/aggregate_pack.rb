# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module AggregatePack
        AGGREGATE_KEYWORDS = %i[count sum avg].freeze

        class << self
          def manifest
            Igniter::Contracts::PackManifest.new(
              name: :extensions_aggregate,
              registry_contracts: AGGREGATE_KEYWORDS.map { |kind| Igniter::Contracts::PackManifest.dsl_keyword(kind) }
            )
          end

          def install_into(kernel)
            install_dsl_keywords(kernel)
            kernel
          end

          def install_dsl_keywords(kernel)
            kernel.dsl_keywords.register(:count, count_keyword)
            kernel.dsl_keywords.register(:sum, sum_keyword)
            kernel.dsl_keywords.register(:avg, avg_keyword)
          end

          def count_keyword
            Igniter::Contracts::DslKeyword.new(:count) do |name, from:, builder:, matching: nil|
              builder.add_operation(
                kind: :compute,
                name: name,
                depends_on: [from.to_sym],
                callable: lambda do |**values|
                  items = AggregatePack.enumerable_source(values.fetch(from.to_sym), source_name: from.to_sym,
                                                                                     operation_name: :count)

                  if matching
                    items.count { |item| matching.call(item) }
                  else
                    items.count
                  end
                end
              )
            end
          end

          def sum_keyword
            Igniter::Contracts::DslKeyword.new(:sum) do |name, from:, builder:, using: nil|
              builder.add_operation(
                kind: :compute,
                name: name,
                depends_on: [from.to_sym],
                callable: lambda do |**values|
                  items = AggregatePack.enumerable_source(values.fetch(from.to_sym), source_name: from.to_sym,
                                                                                     operation_name: :sum)
                  items.reduce(0) do |total, item|
                    total + AggregatePack.extract_value(item, using)
                  end
                end
              )
            end
          end

          def avg_keyword
            Igniter::Contracts::DslKeyword.new(:avg) do |name, from:, builder:, using: nil|
              builder.add_operation(
                kind: :compute,
                name: name,
                depends_on: [from.to_sym],
                callable: lambda do |**values|
                  items = AggregatePack.enumerable_source(values.fetch(from.to_sym), source_name: from.to_sym,
                                                                                     operation_name: :avg)
                  projected = items.map { |item| AggregatePack.extract_value(item, using) }
                  next nil if projected.empty?

                  projected.sum.to_f / projected.length
                end
              )
            end
          end

          def enumerable_source(source, source_name:, operation_name:)
            return source.to_a if source.respond_to?(:to_a)

            raise TypeError, "#{operation_name} source #{source_name} is not enumerable"
          end

          def extract_value(item, projection)
            return item if projection.nil?
            return projection.call(item) if projection.respond_to?(:call)

            key = projection.to_sym
            return item.fetch(key) if item.respond_to?(:key?) && item.key?(key)
            return item.fetch(key.to_s) if item.respond_to?(:key?) && item.key?(key.to_s)

            item.public_send(key)
          end
        end
      end
    end
  end
end
