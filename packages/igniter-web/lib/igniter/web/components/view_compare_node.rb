# frozen_string_literal: true

module Igniter
  module Web
    module Components
      class ViewCompareNode < Component
        builder_method :view_compare_node

        def build(node, &block)
          super(
            class: class_names("ig-node", "ig-compare"),
            "data-ig-node-kind": node.kind,
            "data-ig-node-name": node.name
          )

          h2 node_label(node)
          div class: "ig-compare-grid" do
            compare_side(:left, node.props[:left])
            compare_side(:right, node.props[:right])
          end
          render_property_list(node.props.reject { |key, _| %i[left right].include?(key) })
          render_build_block(block, self)
        end

        private

        def tag_name
          "article"
        end

        def compare_side(side, value)
          section class: class_names("ig-compare-side", token_class("ig-compare-side", side)),
                  "data-ig-compare-side": side do
            h3 humanize(side)
            para format_value(value)
          end
        end
      end
    end
  end
end
