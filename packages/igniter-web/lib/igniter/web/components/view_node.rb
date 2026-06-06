# frozen_string_literal: true

module Igniter
  module Web
    module Components
      class ViewNode < Component
        builder_method :view_node

        def build(node, &block)
          super(
            class: class_names("ig-node", token_class("ig-node", node.kind), token_class("ig-role", node.role)),
            "data-ig-node-kind": node.kind,
            "data-ig-node-name": node.name,
            "data-ig-node-role": node.role
          )

          h2 node_label(node)
          render_property_list(node.props)
          render_build_block(block, self)
        end

        private

        def tag_name
          "article"
        end
      end
    end
  end
end
