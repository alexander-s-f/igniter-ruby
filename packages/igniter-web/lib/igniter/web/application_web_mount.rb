# frozen_string_literal: true

module Igniter
  module Web
    class ApplicationWebMount
      attr_reader :name, :path, :web_application, :application_environment, :metadata

      def initialize(name:, path:, web_application:, application_environment: nil, metadata: {})
        @name = name.to_sym
        @path = normalize_mount_path(path)
        @web_application = web_application
        @application_environment = application_environment
        @metadata = metadata.freeze
      end

      def rack_app
        ->(env) { call(env) }
      end

      def bind(environment:)
        self.class.new(
          name: name,
          path: path,
          web_application: web_application,
          application_environment: environment,
          metadata: metadata
        )
      end

      def context(env = {})
        MountContext.new(
          mount: self,
          application: application_environment,
          env: env
        )
      end

      def call(env)
        request_path = env.fetch("PATH_INFO", "/")
        local_path = local_path_for(request_path)
        return not_found_response(local_path) unless local_path

        route = route_for(local_path)
        return not_found_response(local_path) unless route

        render_route(route, env)
      end

      def to_h
        {
          name: name,
          path: path,
          metadata: metadata,
          surface_manifest: surface_manifest.to_h,
          routes: web_application.routes.map { |route| route_to_h(route) },
          screens: web_application.screens.map { |screen| screen_to_h(screen) }
        }
      end

      private

      def surface_manifest
        SurfaceManifest.for(
          web_application,
          name: name,
          path: path,
          metadata: metadata
        )
      end

      def normalize_mount_path(value)
        candidate = value.to_s
        candidate = "/#{candidate}" unless candidate.start_with?("/")
        candidate.sub(%r{/+\z}, "").then { |path| path.empty? ? "/" : path }
      end

      def local_path_for(request_path)
        return request_path if path == "/"
        return nil unless request_path == path || request_path.start_with?("#{path}/")

        local = request_path.delete_prefix(path)
        local.empty? ? "/" : local
      end

      def route_for(local_path)
        web_application.routes.find { |route| route.path == local_path && route.verb == :get }
      end

      def render_route(route, env)
        body = if route.target.is_a?(Class) && route.target <= Page
                 route.target.render(assigns: route_assigns(env))
               elsif route.target.respond_to?(:graph)
                 ViewGraphRenderer.render(route.target.graph, context: context(env))
               elsif route.target.respond_to?(:call)
                 route.target.call(env)
               else
                 route.target.to_s
               end

        html_response(body)
      end

      def route_assigns(env)
        mount_context = context(env)
        {
          mount: self,
          ctx: mount_context,
          context: mount_context,
          application: application_environment,
          env: env
        }
      end

      def html_response(body)
        [
          200,
          { "content-type" => "text/html; charset=utf-8" },
          [body.to_s]
        ]
      end

      def not_found_response(local_path)
        [
          404,
          { "content-type" => "text/plain; charset=utf-8" },
          ["No igniter-web route for #{local_path}"]
        ]
      end

      def route_to_h(route)
        {
          verb: route.verb,
          path: route.path,
          target: serialize_target(route.target),
          metadata: route.metadata
        }
      end

      def serialize_target(target)
        return target.to_h if target.respond_to?(:to_h)
        return target.name if target.respond_to?(:name)

        target.to_s
      end

      def screen_to_h(screen)
        if screen.respond_to?(:graph)
          {
            screen: screen.screen.name,
            success: screen.success?,
            findings: screen.findings.map(&:to_h),
            graph: screen.graph.to_h
          }
        elsif screen.respond_to?(:to_h)
          screen.to_h
        else
          { screen: screen.to_s }
        end
      end
    end
  end
end
