# frozen_string_literal: true

module Igniter
  module Web
    module Fallback
      class Component
        def self.builder_method(*)
          nil
        end
      end
    end

    class Component < (Arbre.available? ? Arbre.component_class : Fallback::Component)
      class << self
        def define(builder_name = nil, &block)
          klass = Class.new(self)
          klass.builder_method(builder_name) if builder_name
          klass.build_with(&block) if block
          klass
        end

        def build_with(&block)
          return @build_block unless block

          @build_block = block
        end
      end

      def build(*args, **kwargs, &_block)
        build_block = self.class.build_with
        return super(*args, **kwargs) unless build_block

        instance_exec(*args, **kwargs, &build_block)
      rescue NoMethodError => e
        raise unless e.name == :build

        self
      end

      private

      def render_build_block(block, *args)
        return unless block

        if block.arity.zero?
          instance_exec(&block)
        else
          block.call(*args)
        end
      end

      def class_names(*values)
        values.flatten.compact.reject(&:empty?).join(" ")
      end

      def token_class(prefix, value)
        return nil if value.nil?

        "#{prefix}--#{dasherize(value)}"
      end

      def humanize(value)
        value.to_s.tr("_", " ").tr("-", " ").split.map(&:capitalize).join(" ")
      end

      def dasherize(value)
        value.to_s.tr("_", "-").downcase
      end

      def format_value(value)
        case value
        when Symbol
          value.to_s
        when Array
          value.map { |item| format_value(item) }.join(", ")
        when Hash
          value.map { |key, item| "#{humanize(key)}: #{format_value(item)}" }.join(", ")
        else
          value.to_s
        end
      end

      def node_label(node)
        humanize([node.kind, node.name].compact.join(": "))
      end

      def render_property_list(props)
        return if props.empty?

        dl class: "ig-node-props" do
          props.each do |name, value|
            next if value.nil?

            div class: "ig-node-prop", "data-ig-prop": name do
              dt humanize(name)
              dd format_value(value)
            end
          end
        end
      end
    end
  end
end
