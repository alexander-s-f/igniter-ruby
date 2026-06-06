# frozen_string_literal: true

module Igniter
  module Web
    class ViewGraph
      attr_reader :root

      def initialize(root:)
        @root = root
      end

      def zones
        root.children.select { |child| child.kind == :zone }
      end

      def zone(name)
        zones.find { |candidate| candidate.name == name.to_sym }
      end

      def to_h
        { root: root.to_h }
      end
    end
  end
end
