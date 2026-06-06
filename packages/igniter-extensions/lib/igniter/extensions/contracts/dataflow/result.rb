# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Dataflow
        class Result
          attr_reader :processed, :diff, :aggregates, :inputs

          def initialize(processed:, aggregates:, inputs:)
            @processed = processed
            @diff = processed.diff
            @aggregates = aggregates.transform_keys(&:to_sym).freeze
            @inputs = inputs
            freeze
          end

          alias collection processed

          def aggregate(name)
            aggregates.fetch(name.to_sym)
          end

          def output(name)
            aggregate(name)
          end

          def summary
            {
              diff: diff.to_h,
              aggregates: aggregates
            }
          end

          def to_h
            {
              processed: processed.to_h,
              aggregates: aggregates,
              inputs: inputs.to_h
            }
          end

          def method_missing(name, *args)
            return super unless args.empty?
            return processed if name.to_sym == :processed
            return aggregate(name) if aggregates.key?(name.to_sym)

            super
          end

          def respond_to_missing?(name, include_private = false)
            name.to_sym == :processed || aggregates.key?(name.to_sym) || super
          end
        end
      end
    end
  end
end
