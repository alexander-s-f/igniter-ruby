# frozen_string_literal: true

require "uri"

module Igniter
  module Application
    class RackHost
      Route = Struct.new(:http_method, :path, :block, keyword_init: true) do
        def matches?(request_method, request_path)
          http_method == request_method.to_s.upcase && path_params(request_path)
        end

        def path_params(request_path)
          route_segments = path.to_s.split("/")
          request_segments = request_path.to_s.split("/")
          return nil unless route_segments.length == request_segments.length

          route_segments.zip(request_segments).each_with_object({}) do |(route_segment, request_segment), memo|
            if route_segment.start_with?(":")
              memo[route_segment.delete_prefix(":")] = request_segment
            elsif route_segment != request_segment
              return nil
            end
          end
        end

        def to_h
          {
            method: http_method,
            path: path
          }
        end
      end

      class Builder
        attr_reader :name, :root, :env, :metadata, :service_factories, :routes, :web_mounts,
                    :credential_definitions, :ai_block, :agents_block

        def initialize(name, root:, env:, metadata:)
          @name = name.to_sym
          @root = root.to_s
          @env = env.to_sym
          @metadata = metadata.dup
          @service_factories = {}
          @routes = []
          @web_mounts = []
          @credential_definitions = []
          @ai_block = nil
          @agents_block = nil
        end

        def service(name, callable = nil, metadata: {}, &block)
          raise ArgumentError, "service cannot use both a callable and a block" if callable && block

          factory = callable || block
          raise ArgumentError, "service requires an explicit callable or block factory" if factory.nil?
          raise ArgumentError, "service factory for #{name.inspect} must respond to call" unless factory.respond_to?(:call)

          @service_factories[name.to_sym] = {
            factory: factory,
            metadata: metadata
          }
          self
        end

        def mount_web(name, target, at:, capabilities: [], metadata: {})
          @web_mounts << {
            name: name.to_sym,
            target: target,
            at: at.to_s,
            capabilities: capabilities.map(&:to_sym),
            metadata: metadata.dup
          }
          self
        end

        def credential(name, env: nil, required: false, description: nil, metadata: {})
          @credential_definitions << {
            name: name,
            env: env,
            required: required,
            description: description,
            metadata: metadata
          }
          self
        end

        def ai(&block)
          raise ArgumentError, "ai requires a block" unless block

          @ai_block = block
          self
        end

        def agents(&block)
          raise ArgumentError, "agents requires a block" unless block

          @agents_block = block
          self
        end

        def get(path, &block)
          route("GET", path, &block)
        end

        def post(path, &block)
          route("POST", path, &block)
        end

        def build
          service_instances = {}
          kernel = Kernel.new
          kernel.manifest(name, root: root, env: env, metadata: metadata)
          kernel.ai(&ai_block) if ai_block
          kernel.agents(&agents_block) if agents_block
          credential_definitions.each do |definition|
            kernel.credential(
              definition.fetch(:name),
              env: definition.fetch(:env),
              required: definition.fetch(:required),
              description: definition.fetch(:description),
              metadata: definition.fetch(:metadata)
            )
          end
          service_factories.each do |service_name, entry|
            kernel.provide(service_name, -> { service_instances.fetch(service_name) }, metadata: entry.fetch(:metadata))
          end
          web_mounts.each do |mount|
            kernel.mount_web(
              mount.fetch(:name),
              mount.fetch(:target),
              at: mount.fetch(:at),
              capabilities: mount.fetch(:capabilities),
              metadata: mount.fetch(:metadata)
            )
          end

          environment = Environment.new(profile: kernel.finalize)
          service_instances.merge!(build_service_instances(environment))
          RackHost.new(
            name: name,
            root: root,
            env: env,
            environment: environment,
            service_instances: service_instances,
            routes: routes,
            web_mounts: web_mounts
          )
        end

        private

        def route(method, path, &block)
          raise ArgumentError, "#{method} #{path} requires a block" unless block

          @routes << Route.new(http_method: method, path: path.to_s, block: block)
          self
        end

        def build_service_instances(environment)
          service_factories.transform_values do |entry|
            factory = entry.fetch(:factory)
            factory.arity.zero? ? factory.call : factory.call(environment)
          end
        end
      end

      class Context
        attr_reader :host, :env, :params

        def initialize(host:, env:, params:)
          @host = host
          @env = env
          @params = params
        end

        def service(name)
          host.service(name)
        end

        def text(body, status: 200, content_type: "text/plain; charset=utf-8")
          [status, { "content-type" => content_type }, [body.to_s]]
        end

        def redirect(location, status: 303)
          [status, { "location" => location.to_s, "content-type" => "text/plain; charset=utf-8" }, ["See #{location}"]]
        end

        def not_found(body = "not found")
          text(body, status: 404)
        end
      end

      attr_reader :name, :root, :env, :environment, :service_instances, :routes, :web_mounts

      def self.build(name, root:, env: :development, metadata: {}, &block)
        raise ArgumentError, "rack_app requires a block" unless block

        builder = Builder.new(name, root: root, env: env, metadata: metadata)
        builder.instance_eval(&block)
        builder.build
      end

      def initialize(name:, root:, env:, environment:, service_instances:, routes:, web_mounts:)
        @name = name.to_sym
        @root = root.to_s
        @env = env.to_sym
        @environment = environment
        @service_instances = service_instances.dup.freeze
        @routes = routes.dup.freeze
        @web_mounts = web_mounts.map(&:dup).freeze
        @bound_web_mounts = bind_web_mounts
        freeze
      end

      def call(env)
        request_method = env.fetch("REQUEST_METHOD", "GET").to_s.upcase
        path = env.fetch("PATH_INFO", "/").to_s

        route = routes.find { |entry| entry.matches?(request_method, path) }
        return call_route(route, env) if route

        mounted_response = call_web_mount(request_method, path, env)
        return mounted_response if mounted_response

        Context.new(host: self, env: env, params: {}).not_found
      end

      def service(name)
        environment.service(name).call
      end

      def to_h
        {
          name: name,
          root: root,
          env: env,
          manifest: environment.manifest.to_h,
          services: service_instances.keys.sort,
          routes: routes.map(&:to_h),
          web_mounts: web_mounts.map do |mount|
            {
              name: mount.fetch(:name),
              at: mount.fetch(:at),
              capabilities: mount.fetch(:capabilities),
              metadata: mount.fetch(:metadata)
            }
          end
        }
      end

      private

      def call_route(route, env)
        context = Context.new(host: self, env: env, params: params_for(env).merge(route.path_params(env.fetch("PATH_INFO", "/").to_s) || {}))
        result = if route.block.arity.zero?
                   context.instance_exec(&route.block)
                 else
                   context.instance_exec(context.params, &route.block)
                 end
        normalize_response(result, context: context)
      end

      def call_web_mount(request_method, path, env)
        return nil unless request_method == "GET"

        mount = web_mounts.find { |entry| entry.fetch(:at) == path }
        return nil unless mount

        target = @bound_web_mounts.fetch(mount.fetch(:name))
        rack_app = target.respond_to?(:rack_app) ? target.rack_app : target
        return rack_app.call(env) if rack_app.respond_to?(:call)

        nil
      end

      def bind_web_mounts
        web_mounts.each_with_object({}) do |mount, memo|
          target = mount.fetch(:target)
          memo[mount.fetch(:name)] = target.respond_to?(:bind) ? target.bind(environment: environment) : target
        end.freeze
      end

      def params_for(env)
        case env.fetch("REQUEST_METHOD", "GET").to_s.upcase
        when "POST", "PUT", "PATCH", "DELETE"
          URI.decode_www_form(read_body(env)).to_h
        else
          URI.decode_www_form(env.fetch("QUERY_STRING", "").to_s).to_h
        end
      end

      def read_body(env)
        input = env["rack.input"]
        input ? input.read.to_s : ""
      ensure
        input&.rewind
      end

      def normalize_response(result, context:)
        return result if rack_response?(result)

        context.text(result.to_s)
      end

      def rack_response?(result)
        result.is_a?(Array) && result.size == 3 && result[0].is_a?(Integer) && result[1].is_a?(Hash)
      end
    end
  end
end
