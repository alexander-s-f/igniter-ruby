# frozen_string_literal: true

module Igniter
  module Web
    module Components
      class ViewAskNode < Component
        builder_method :view_ask_node

        def build(node, &block)
          field_id = "ig-field-#{dasherize(node.name || :input)}"
          super(
            class: class_names("ig-node", "ig-field", token_class("ig-field", node.props[:as])),
            "data-ig-node-kind": node.kind,
            "data-ig-node-name": node.name,
            "data-ig-field": node.name
          )

          label humanize(node.name), for: field_id
          render_input(node, field_id)
          render_property_list(node.props.reject { |key, _| key == :as })
          render_build_block(block, self)
        end

        private

        def tag_name
          "article"
        end

        def render_input(node, field_id)
          case node.props[:as]
          when :textarea
            textarea "", id: field_id, name: node.name
          else
            input id: field_id, name: node.name, type: input_type_for(node.props[:as])
          end
        end

        def input_type_for(kind)
          case kind
          when :email
            "email"
          when :number
            "number"
          else
            "text"
          end
        end
      end
    end
  end
end
