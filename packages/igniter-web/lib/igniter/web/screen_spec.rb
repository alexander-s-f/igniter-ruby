# frozen_string_literal: true

module Igniter
  module Web
    class ScreenSpec
      Element = Struct.new(:kind, :name, :role, :options, keyword_init: true) do
        def to_h
          {
            kind: kind,
            name: name,
            role: role,
            options: options
          }.compact
        end
      end

      class << self
        def build(name, intent: nil, **options, &block)
          new(name: name, intent: intent, **options).tap { |screen| screen.draw(&block) if block }
        end
      end

      attr_reader :name, :intent, :options, :elements, :composition_preset, :title_text

      def initialize(name:, intent: nil, **options)
        @name = name.to_sym
        @intent = intent&.to_sym
        @options = options.freeze
        @elements = []
        @composition_preset = nil
        @title_text = nil
      end

      def draw(&block)
        instance_eval(&block) if block
        self
      end

      def title(value)
        @title_text = value
        self
      end

      def compose(with:)
        @composition_preset = with.to_sym
        self
      end

      def subject(name, **options)
        add_element(:subject, name, role: :summary, **options)
      end

      def actor(name, **options)
        add_element(:actor, name, role: :aside, **options)
      end

      def show(name, role: nil, **options)
        add_element(:show, name, role: role, **options)
      end

      def need(name, role: nil, **options)
        add_element(:need, name, role: role, **options)
      end

      def ask(name, as: :text, **options)
        add_element(:ask, name, role: :input, as: as, **options)
      end

      def compare(left, right, name: nil, **options)
        add_element(:compare, name || :"#{left}_to_#{right}", left: left, right: right, **options)
      end

      def stream(name, from: nil, **options)
        add_element(:stream, name, from: from, **options)
      end

      def chat(with:, **options)
        add_element(:chat, with, role: :aside, **options)
      end

      def action(name, run: nil, destructive: false, **options)
        add_element(:action, name, role: :primary_action, run: run, destructive: destructive, **options)
      end

      def to_h
        {
          name: name,
          intent: intent,
          title: title_text,
          compose_with: composition_preset,
          options: options,
          elements: elements.map(&:to_h)
        }.compact
      end

      private

      def add_element(kind, name, role: nil, **options)
        elements << Element.new(
          kind: kind.to_sym,
          name: name&.to_sym,
          role: role&.to_sym,
          options: options.freeze
        )
        self
      end
    end
  end
end
