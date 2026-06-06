# frozen_string_literal: true

module Igniter
  module Web
    class CompositionResult
      attr_reader :screen, :graph, :findings

      def initialize(screen:, graph:, findings: [])
        @screen = screen
        @graph = graph
        @findings = findings.freeze
      end

      def success?
        findings.none? { |finding| finding.severity == :error }
      end

      def to_h
        {
          screen: screen.to_h,
          graph: graph.to_h,
          findings: findings.map(&:to_h)
        }
      end
    end
  end
end
