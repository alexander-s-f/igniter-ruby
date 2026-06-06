# frozen_string_literal: true

module Igniter
  module Web
    module Components
      class ViewStreamNode < Component
        builder_method :view_stream_node

        def build(node, &block)
          super(
            class: class_names("ig-node", "ig-stream", token_class("ig-stream", node.name)),
            "data-ig-node-kind": node.kind,
            "data-ig-node-name": node.name,
            "data-ig-stream": node.name,
            "data-ig-stream-from": node.props[:from]
          )

          h2 node_label(node)
          ol class: "ig-stream-feed", "data-ig-stream-feed": node.name
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
