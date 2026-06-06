# frozen_string_literal: true

module Igniter
  module Web
    module Components
      class ViewZone < Component
        builder_method :view_zone

        def build(zone, &block)
          super(
            class: class_names("ig-zone", token_class("ig-zone", zone.name)),
            "data-ig-zone": zone.name
          )

          render_build_block(block, self)
        end

        private

        def tag_name
          "section"
        end
      end
    end
  end
end
