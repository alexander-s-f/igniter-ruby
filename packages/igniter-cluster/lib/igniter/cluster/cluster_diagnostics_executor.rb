# frozen_string_literal: true

module Igniter
  module Cluster
    class ClusterDiagnosticsExecutor
      attr_reader :metadata

      def initialize(metadata: {})
        @metadata = metadata.dup.freeze
        freeze
      end

      def execute_transport(query:, placement:, route:, projection_report:, admission:, metadata: {})
        resolved_status = admission.fetch(:allowed, false) ? :completed : :failed
        event_log = build_transport_event_log(
          placement: placement,
          route: route,
          projection_report: projection_report,
          admission: admission,
          metadata: metadata
        )
        operator_timeline = build_timeline(
          kind: :transport,
          status: resolved_status,
          event_log: event_log,
          metadata: metadata
        )

        ClusterDiagnosticsReport.new(
          kind: :transport,
          status: resolved_status,
          query: query,
          placement: placement,
          route: route,
          projection_report: projection_report,
          admission: admission,
          event_log: event_log,
          operator_timeline: operator_timeline,
          metadata: self.metadata.merge(metadata),
          explanation: DecisionExplanation.new(
            code: :transport_diagnostics,
            message: "transport diagnostics resolved #{route.fetch(:peer)}",
            metadata: {
              peer: route.fetch(:peer),
              route_mode: route.fetch(:mode),
              placement_mode: placement.fetch(:mode)
            }
          )
        )
      end

      def execute_mesh(query:, projection_report:, mesh:, status:, metadata: {})
        event_log = build_mesh_event_log(
          projection_report: projection_report,
          mesh: mesh,
          metadata: metadata
        )
        operator_timeline = build_timeline(
          kind: :mesh,
          status: status,
          event_log: event_log,
          metadata: metadata
        )

        ClusterDiagnosticsReport.new(
          kind: :mesh,
          status: status,
          query: query,
          projection_report: projection_report,
          mesh: mesh,
          event_log: event_log,
          operator_timeline: operator_timeline,
          metadata: self.metadata.merge(metadata),
          explanation: DecisionExplanation.new(
            code: :mesh_diagnostics,
            message: "mesh diagnostics captured #{mesh.fetch(:attempt_count)} attempt(s)",
            metadata: {
              trace_id: mesh.fetch(:trace_id),
              plan_kind: mesh.fetch(:plan_kind),
              attempt_count: mesh.fetch(:attempt_count)
            }
          )
        )
      end

      private

      def build_transport_event_log(placement:, route:, projection_report:, admission:, metadata:)
        ClusterEventLog.new(
          events: [
            ClusterEvent.new(
              kind: :placement,
              status: :resolved,
              metadata: {
                mode: placement.fetch(:mode),
                candidate_names: placement.fetch(:candidates)
              }
            ),
            ClusterEvent.new(
              kind: :projection,
              status: projection_report.fetch(:status),
              metadata: {
                mode: projection_report.fetch(:mode),
                candidate_names: projection_report.fetch(:candidate_names)
              }
            ),
            ClusterEvent.new(
              kind: :route,
              status: :resolved,
              metadata: {
                peer: route.fetch(:peer),
                mode: route.fetch(:mode)
              }
            ),
            ClusterEvent.new(
              kind: :admission,
              status: admission.fetch(:allowed) ? :allowed : :denied,
              metadata: {
                code: admission.fetch(:code),
                peer: route.fetch(:peer)
              }
            )
          ],
          metadata: self.metadata.merge(metadata)
        )
      end

      def build_mesh_event_log(projection_report:, mesh:, metadata:)
        attempt_events = Array(mesh[:attempt_statuses]).each_with_index.map do |attempt_status, index|
          ClusterEvent.new(
            kind: :mesh_attempt,
            status: attempt_status,
            metadata: {
              sequence: index + 1,
              plan_kind: mesh.fetch(:plan_kind)
            }
          )
        end

        ClusterEventLog.new(
          events: [
            ClusterEvent.new(
              kind: :projection,
              status: projection_report.fetch(:status),
              metadata: {
                mode: projection_report.fetch(:mode),
                candidate_names: projection_report.fetch(:candidate_names)
              }
            ),
            *attempt_events,
            ClusterEvent.new(
              kind: :mesh,
              status: mesh.fetch(:attempt_statuses).last || :failed,
              metadata: {
                trace_id: mesh.fetch(:trace_id),
                plan_kind: mesh.fetch(:plan_kind),
                attempt_count: mesh.fetch(:attempt_count)
              }
            )
          ],
          metadata: self.metadata.merge(metadata)
        )
      end

      def build_timeline(kind:, status:, event_log:, metadata:)
        OperatorTimeline.new(
          kind: kind,
          status: status,
          event_log: event_log,
          metadata: self.metadata.merge(metadata),
          explanation: DecisionExplanation.new(
            code: :operator_timeline,
            message: "#{kind} timeline captured #{event_log.event_count} event(s)",
            metadata: {
              kind: kind,
              status: status,
              event_count: event_log.event_count
            }
          )
        )
      end
    end
  end
end
