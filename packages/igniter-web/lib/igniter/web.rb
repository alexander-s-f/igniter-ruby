# frozen_string_literal: true

require "igniter/application"

require_relative "web/arbre"
require_relative "web/api"
require_relative "web/application"
require_relative "web/composition_finding"
require_relative "web/view_node"
require_relative "web/view_graph"
require_relative "web/screen_spec"
require_relative "web/composition_preset"
require_relative "web/composition_policy"
require_relative "web/composition_result"
require_relative "web/composer"
require_relative "web/component"
require_relative "web/components"
require_relative "web/view_graph_renderer"
require_relative "web/page"
require_relative "web/record"
require_relative "web/mount_context"
require_relative "web/application_web_mount"
require_relative "web/interaction_target"
require_relative "web/surface_structure"
require_relative "web/surface_manifest"
require_relative "web/flow_interaction_adapter"
require_relative "web/flow_surface_projection"

module Igniter
  module Web
    class << self
      def application(&block)
        Application.new.draw(&block)
      end

      def api(&block)
        Api.new.draw(&block)
      end

      def screen(name, intent: nil, **options, &block)
        ScreenSpec.build(name, intent: intent, **options, &block)
      end

      def compose(screen = nil, **options, &block)
        spec = screen || ScreenSpec.build(options.fetch(:name, :anonymous), **options, &block)
        Composer.compose(spec)
      end

      def render(graph, context: nil)
        ViewGraphRenderer.render(graph, context: context)
      end

      def mount(name, path:, application: application(&nil), environment: nil, metadata: {})
        ApplicationWebMount.new(
          name: name,
          path: path,
          web_application: application,
          application_environment: environment,
          metadata: metadata
        )
      end

      def contract(name)
        InteractionTarget.contract(name)
      end

      def service(name)
        InteractionTarget.service(name)
      end

      def projection(name)
        InteractionTarget.projection(name)
      end

      def surface_structure(blueprint = nil, web_root: nil, **options)
        return SurfaceStructure.for(blueprint, **options) unless blueprint.nil?

        SurfaceStructure.new(web_root: web_root || "app/web", **options)
      end

      def surface_manifest(application, name:, path: nil, metadata: {})
        SurfaceManifest.for(application, name: name, path: path, metadata: metadata)
      end

      def flow_pending_state(source, current_step: nil, metadata: {})
        FlowInteractionAdapter.pending_state(source, current_step: current_step, metadata: metadata)
      end

      def flow_surface_projection(surface, declaration:, feature: nil, metadata: {})
        FlowSurfaceProjection.project(surface, declaration: declaration, feature: feature, metadata: metadata)
      end

      def surface_metadata(surface, projections: {})
        return surface.to_surface_metadata(projections: projections) if surface.respond_to?(:to_surface_metadata)

        payload = surface.respond_to?(:to_h) ? surface.to_h : { surface: surface }
        projections.empty? ? payload : payload.merge(projections: projections)
      end

      def flow_surface_metadata(surface, declaration:, feature: nil, metadata: {})
        projection = flow_surface_projection(surface, declaration: declaration, feature: feature, metadata: metadata)

        surface_metadata(surface, projections: { flow_surface: projection })
      end
    end
  end
end
