# frozen_string_literal: true

module Igniter
  module Web
    class Composer
      class << self
        def compose(...)
          new.compose(...)
        end
      end

      def initialize(policy: CompositionPolicy.new)
        @policy = policy
      end

      def compose(screen)
        preset = CompositionPreset.fetch(screen.composition_preset)
        graph = ViewGraph.new(root: root_node(screen, preset))
        CompositionResult.new(
          screen: screen,
          graph: graph,
          findings: @policy.findings_for(screen, preset: preset)
        )
      end

      private

      def root_node(screen, preset)
        zones = preset.zone_order.map { |name| zone_node(name, screen, preset) }
        ViewNode.new(
          kind: :screen,
          name: screen.name,
          role: screen.intent,
          props: {
            title: screen.title_text,
            preset: preset.to_h,
            options: screen.options
          }.compact,
          children: zones
        )
      end

      def zone_node(name, screen, preset)
        children = screen.elements
                         .select { |element| zone_for(element, preset) == name }
                         .map { |element| element_node(element) }

        ViewNode.new(
          kind: :zone,
          name: name,
          children: children
        )
      end

      def element_node(element)
        ViewNode.new(
          kind: element.kind,
          name: element.name,
          role: element.role,
          props: element.options
        )
      end

      def zone_for(element, preset)
        preset_zone = preset.preferred_zone_for(element.kind)
        return preset_zone if preset_zone

        return :summary if element.role == :summary
        return :aside if element.role == :aside
        return :footer if element.kind == :action
        return :main if %i[ask compare stream].include?(element.kind)

        case element.kind
        when :subject
          :summary
        when :actor, :chat
          :aside
        else
          :main
        end
      end
    end
  end
end
