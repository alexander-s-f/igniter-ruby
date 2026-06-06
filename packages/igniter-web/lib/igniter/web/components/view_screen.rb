# frozen_string_literal: true

module Igniter
  module Web
    module Components
      class ViewScreen < Component
        builder_method :view_screen

        def build(root, options = {}, &block)
          title = options.fetch(:title)
          preset = root.props.fetch(:preset, {})
          super(
            class: class_names("ig-screen", token_class("ig-screen", root.role), token_class("ig-preset", preset[:name])),
            "data-ig-screen": root.name,
            "data-ig-intent": root.role,
            "data-ig-preset": preset[:name]
          )

          header class: "ig-screen-header" do
            h1 title
          end

          render_build_block(block, self)
        end

        private

        def tag_name
          "main"
        end
      end
    end
  end
end
