# frozen_string_literal: true

module Igniter
  module Web
    class ViewNode
      attr_reader :kind, :name, :role, :props, :children

      def initialize(kind:, name: nil, role: nil, props: {}, children: [])
        @kind = kind.to_sym
        @name = name&.to_sym
        @role = role&.to_sym
        @props = props.freeze
        @children = children.freeze
      end

      def add(child)
        self.class.new(
          kind: kind,
          name: name,
          role: role,
          props: props,
          children: children + [child]
        )
      end

      def to_h
        {
          kind: kind,
          name: name,
          role: role,
          props: props,
          children: children.map(&:to_h)
        }.compact
      end
    end
  end
end
