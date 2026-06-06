# frozen_string_literal: true

module Igniter
  module Web
    class ViewGraphRenderer
      class << self
        def render(...)
          new.render(...)
        end
      end

      def render(graph, context: nil)
        Arbre.ensure_available!
        arbre_context = Arbre.context_class.new(graph: graph, ctx: context, context: context)
        arbre_context.extend(RenderingHelpers)
        arbre_context.instance_exec(graph) do |view_graph|
          html do
            head do
              meta charset: "utf-8"
              title screen_title(view_graph.root)
            end

            body do
              view_screen view_graph.root, title: screen_title(view_graph.root) do
                view_graph.zones.each { |zone| render_zone(zone) }
              end
            end
          end
        end
        arbre_context.to_s
      end

      module RenderingHelpers
        def screen_title(root)
          root.props[:title] || humanize(root.name || :screen)
        end

        def render_zone(zone)
          view_zone zone do
            zone.children.each { |child| render_node(child) }
          end
        end

        def render_node(node)
          send(node_builder_method(node), node) do
            node.children.each { |child| render_node(child) }
          end
        end

        def node_builder_method(node)
          candidate = :"view_#{node.kind}_node"
          return candidate if respond_to?(candidate)

          :view_node
        end

        def humanize(value)
          value.to_s.tr("_", " ").tr("-", " ").split.map(&:capitalize).join(" ")
        end
      end
    end
  end
end
