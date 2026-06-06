# frozen_string_literal: true

module Igniter
  module Web
    module Components
      class ViewChatNode < Component
        builder_method :view_chat_node

        def build(node, &block)
          super(
            class: class_names("ig-node", "ig-chat", token_class("ig-chat", node.name)),
            "data-ig-node-kind": node.kind,
            "data-ig-node-name": node.name,
            "data-ig-chat-with": node.name
          )

          header class: "ig-chat-header" do
            h2 "Conversation"
            span format_value(node.name), class: "ig-chat-agent"
          end
          div class: "ig-chat-feed", "data-ig-chat-feed": node.name
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
