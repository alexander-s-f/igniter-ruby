# frozen_string_literal: true

module Igniter
  module Web
    class Application
      Route = Struct.new(:verb, :path, :target, :metadata, keyword_init: true)
      Mount = Struct.new(:path, :target, :metadata, keyword_init: true)

      attr_reader :routes, :mounts, :api_surface, :pages, :screens

      def initialize(api: nil)
        @routes = []
        @mounts = []
        @api_surface = api
        @pages = []
        @screens = []
      end

      def draw(&block)
        instance_eval(&block) if block
        self
      end

      %i[get post put patch delete].each do |verb|
        define_method(verb) do |path, to:, **metadata|
          @routes << Route.new(
            verb: verb,
            path: path,
            target: to,
            metadata: metadata.freeze
          )
          self
        end
      end

      def mount(path, to:, **metadata)
        @mounts << Mount.new(path: path, target: to, metadata: metadata.freeze)
        self
      end

      def root(to: nil, title: nil, **metadata, &block)
        page("/", to: to, title: title, **metadata, &block)
      end

      def page(path, to: nil, title: nil, **metadata, &block)
        target = if to
                   to
                 elsif block
                   Page.define(title: title, &block)
                 else
                   raise ArgumentError, "page requires either `to:` or a block"
                 end

        @pages << target if target.is_a?(Class) && target <= Page
        get(path, to: target, page: true, title: title, **metadata)
      end

      def screen(name, intent: nil, compose: true, **options, &block)
        spec = ScreenSpec.build(name, intent: intent, **options, &block)
        @screens << (compose ? Composer.compose(spec) : spec)
        self
      end

      def screen_route(path, screen_name, **metadata)
        screen = @screens.find do |candidate|
          candidate.respond_to?(:screen) && candidate.screen.name == screen_name.to_sym
        end
        raise ArgumentError, "unknown composed screen: #{screen_name.inspect}" unless screen

        get(path, to: screen, screen: true, **metadata)
      end

      def api(&block)
        @api_surface ||= Api.new
        @api_surface.draw(&block)
      end

      def command(...)
        api.command(...)
        self
      end

      def query(...)
        api.query(...)
        self
      end

      def stream(...)
        api.stream(...)
        self
      end

      def webhook(...)
        api.webhook(...)
        self
      end
    end
  end
end
