# frozen_string_literal: true

module Igniter
  module Web
    class Page
      class << self
        def inherited(subclass)
          super
          subclass.title(title)
          subclass.layout(&layout_block) if instance_variable_defined?(:@layout_block)
          subclass.body(&body_block) if instance_variable_defined?(:@body_block)
        end

        def define(title: nil, &block)
          klass = Class.new(self)
          klass.title(title) unless title.nil?
          klass.body(&block) if block
          klass
        end

        def title(value = nil)
          return @title if value.nil?

          @title = value
        end

        def body(&block)
          return @body_block unless block

          @body_block = block
        end

        def layout(&block)
          return @layout_block unless block

          @layout_block = block
        end

        def render(**kwargs)
          new(**kwargs).render
        end
      end

      attr_reader :assigns, :current_arbre_context

      def initialize(assigns: {})
        @assigns = assigns
      end

      def render
        body_context = build_context(&self.class.body)
        @body_context = body_context
        build_context(&resolved_layout).to_s
      ensure
        @body_context = nil
      end

      def page_title
        self.class.title || self.class.name || "Igniter Web Page"
      end

      def render_body
        raise ArgumentError, "#{self.class} has no body content to render" unless @body_context

        target = current_arbre_context&.current_arbre_element
        raise ArgumentError, "#{self.class} has no active Arbre context" unless target

        @body_context.children.to_a.each do |child|
          if target.respond_to?(:add_child)
            target.add_child(child)
          else
            target << child
          end
        end

        nil
      end

      private

      def resolved_layout
        self.class.layout || proc do
          html do
            head do
              meta charset: "utf-8"
              title page_title
            end

            body do
              render_body
            end
          end
        end
      end

      def build_context(&block)
        raise ArgumentError, "#{self.class} must define a page body" unless block

        Arbre.ensure_available!
        context = Arbre.context_class.new(assigns, self)
        previous_context = @current_arbre_context
        @current_arbre_context = context
        context.instance_exec(&block)
        context
      ensure
        @current_arbre_context = previous_context
      end
    end
  end
end
