# frozen_string_literal: true

module Igniter
  module Web
    class CompositionPreset
      DEFAULT_ZONE_ORDER = %i[summary main aside footer].freeze

      PRESETS = {
        decision_workspace: {
          intent: :human_decision,
          zone_order: DEFAULT_ZONE_ORDER,
          preferred_zones: {
            subject: :summary,
            show: :main,
            compare: :main,
            chat: :aside,
            actor: :aside,
            action: :footer
          },
          policy_hints: {
            requires_action: true,
            prefers_aside_companion: true
          }
        },
        operator_console: {
          intent: :live_process,
          zone_order: %i[summary main aside footer],
          preferred_zones: {
            subject: :summary,
            need: :summary,
            stream: :main,
            show: :main,
            compare: :main,
            chat: :aside,
            actor: :aside,
            action: :footer
          },
          policy_hints: {
            prefers_live_surface: true,
            supports_agent_companion: true
          }
        },
        wizard_operator_surface: {
          intent: :guided_process,
          zone_order: %i[summary main footer aside],
          preferred_zones: {
            subject: :summary,
            ask: :main,
            show: :main,
            compare: :main,
            stream: :aside,
            chat: :aside,
            actor: :aside,
            action: :footer
          },
          policy_hints: {
            step_first: true,
            prefers_footer_actions: true
          }
        },
        live_process: {
          intent: :live_process,
          zone_order: DEFAULT_ZONE_ORDER,
          preferred_zones: {
            subject: :summary,
            need: :summary,
            stream: :main,
            show: :main,
            chat: :aside,
            actor: :aside,
            action: :footer
          },
          policy_hints: {
            prefers_live_surface: true
          }
        }
      }.freeze

      class << self
        def fetch(name)
          key = (name || :default).to_sym
          return default if key == :default

          config = PRESETS.fetch(key) do
            raise ArgumentError, "unknown composition preset: #{name.inspect}"
          end

          new(name: key, **config)
        end

        def default
          new(
            name: :default,
            intent: nil,
            zone_order: DEFAULT_ZONE_ORDER,
            preferred_zones: {},
            policy_hints: {}
          )
        end

        def names
          PRESETS.keys
        end
      end

      attr_reader :name, :intent, :zone_order, :preferred_zones, :policy_hints

      def initialize(name:, intent:, zone_order:, preferred_zones:, policy_hints:)
        @name = name.to_sym
        @intent = intent&.to_sym
        @zone_order = zone_order.map(&:to_sym).freeze
        @preferred_zones = preferred_zones.transform_keys(&:to_sym).transform_values(&:to_sym).freeze
        @policy_hints = policy_hints.freeze
      end

      def preferred_zone_for(kind)
        preferred_zones[kind.to_sym]
      end

      def to_h
        {
          name: name,
          intent: intent,
          zone_order: zone_order,
          preferred_zones: preferred_zones,
          policy_hints: policy_hints
        }.compact
      end
    end
  end
end
