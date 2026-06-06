# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Audit
        class Snapshot
          attr_reader :graph, :profile_fingerprint, :event_count, :events, :states, :children, :output_names

          def initialize(graph:, profile_fingerprint:, events:, states:, children:, output_names:)
            @graph = graph.to_s
            @profile_fingerprint = profile_fingerprint
            @events = events.freeze
            @states = states.transform_keys(&:to_sym).freeze
            @children = children.freeze
            @output_names = output_names.map(&:to_sym).freeze
            @event_count = @events.length
            freeze
          end

          def event_types
            events.map(&:type).uniq
          end

          def state(name)
            states.fetch(name.to_sym)
          end

          def to_h
            {
              graph: graph,
              profile_fingerprint: profile_fingerprint,
              event_count: event_count,
              output_names: output_names,
              events: events.map(&:to_h),
              states: states,
              children: children
            }
          end
        end
      end
    end
  end
end
