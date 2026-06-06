# frozen_string_literal: true

module Igniter
  module Cluster
    class ClusterDiagnosticsReport
      attr_reader :kind, :status, :query, :placement, :route, :projection_report,
                  :admission, :mesh, :event_log, :operator_timeline, :metadata, :explanation

      def initialize(kind:, status:, query: nil, placement: nil, route: nil, projection_report: nil,
                     admission: nil, mesh: nil, event_log: nil, operator_timeline: nil, metadata: {},
                     explanation: nil)
        @kind = kind.to_sym
        @status = status.to_sym
        @query = query&.dup&.freeze
        @placement = placement&.dup&.freeze
        @route = route&.dup&.freeze
        @projection_report = projection_report&.dup&.freeze
        @admission = admission&.dup&.freeze
        @mesh = mesh&.dup&.freeze
        @event_log = event_log
        @operator_timeline = operator_timeline
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: @status,
          metadata: @metadata
        )
        freeze
      end

      def to_h
        {
          kind: kind,
          status: status,
          query: query&.dup,
          placement: placement&.dup,
          route: route&.dup,
          projection_report: projection_report&.dup,
          admission: admission&.dup,
          mesh: mesh&.dup,
          event_log: event_log&.to_h,
          operator_timeline: operator_timeline&.to_h,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }.compact
      end
    end
  end
end
