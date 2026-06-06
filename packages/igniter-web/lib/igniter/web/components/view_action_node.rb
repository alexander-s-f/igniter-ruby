# frozen_string_literal: true

module Igniter
  module Web
    module Components
      class ViewActionNode < Component
        builder_method :view_action_node

        def build(node, &block)
          super(
            class: class_names(
              "ig-node",
              "ig-action",
              token_class("ig-action", node.name),
              token_class("ig-role", node.role)
            ),
            "data-ig-node-kind": node.kind,
            "data-ig-node-name": node.name,
            "data-ig-node-role": node.role,
            "data-ig-action": node.name
          )

          button type: "button", class: "ig-action-button", "data-ig-action-run": node.props[:run] do
            span humanize(node.name || :action), class: "ig-action-label"
          end
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
