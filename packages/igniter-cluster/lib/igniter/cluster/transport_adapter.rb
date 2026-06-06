# frozen_string_literal: true

module Igniter
  module Cluster
    class TransportAdapter
      attr_reader :diagnostics_executor

      def initialize(diagnostics_executor: ClusterDiagnosticsExecutor.new(metadata: { scope: :transport }))
        @diagnostics_executor = diagnostics_executor
        freeze
      end

      def call(route:, request:, placement:, admission:)
        response = route.peer.transport.call(request: request)
        ensure_transport_response!(route, response)

        Igniter::Application::TransportResponse.new(
          result: response.result,
          metadata: response.metadata.merge(cluster: cluster_metadata(placement, route, admission))
        )
      end

      private

      def ensure_transport_response!(route, response)
        return if response.is_a?(Igniter::Application::TransportResponse)

        raise Error,
              "cluster transport for #{route.peer.name} must return " \
              "Igniter::Application::TransportResponse"
      end

      def cluster_metadata(placement, route, admission)
        diagnostics_report = diagnostics_executor.execute_transport(
          query: route.metadata[:query],
          placement: placement.to_h,
          route: route.to_h,
          projection_report: route.projection_report&.to_h || placement.projection_report&.to_h,
          admission: admission.to_h
        )

        {
          query: route.metadata[:query],
          placement: placement.to_h,
          route: route.to_h,
          projection_report: route.projection_report&.to_h || placement.projection_report&.to_h,
          admission: admission.to_h,
          diagnostics_report: diagnostics_report.to_h
        }
      end
    end
  end
end
