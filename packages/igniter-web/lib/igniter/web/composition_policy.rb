# frozen_string_literal: true

module Igniter
  module Web
    class CompositionPolicy
      def findings_for(screen, preset: CompositionPreset.default)
        findings = []
        findings.concat(preset_findings(screen, preset))
        findings.concat(intent_findings(screen))
        findings.concat(action_findings(screen))
        findings
      end

      private

      def preset_findings(screen, preset)
        return [] unless preset.policy_hints[:requires_action]
        return [] if screen.elements.any? { |element| element.kind == :action }

        [finding(
          :error,
          :missing_preset_action,
          "#{screen.name} uses #{preset.name} but has no action.",
          ["add an action", "choose a less action-oriented preset"]
        )]
      end

      def intent_findings(screen)
        case screen.intent
        when :human_decision
          return [] if screen.elements.any? { |element| element.kind == :action }

          [finding(
            :error,
            :missing_primary_action,
            "#{screen.name} declares human decision intent but has no action.",
            ["add an action", "mark the screen read-only"]
          )]
        when :collect_input
          return [] if screen.elements.any? { |element| element.kind == :ask }

          [finding(
            :error,
            :missing_input,
            "#{screen.name} declares input collection intent but has no input.",
            ["add ask :field_name", "use a different intent"]
          )]
        when :live_process
          live_kinds = %i[stream chat need]
          return [] if screen.elements.any? { |element| live_kinds.include?(element.kind) }

          [finding(
            :warning,
            :missing_live_surface,
            "#{screen.name} declares live process intent but has no stream, chat, or live need.",
            ["add stream :events", "add chat with: Agent", "add need :progress"]
          )]
        else
          []
        end
      end

      def action_findings(screen)
        screen.elements.filter_map do |element|
          next unless element.kind == :action
          next unless element.options.fetch(:destructive, false)
          next if element.options[:confirm]

          finding(
            :warning,
            :missing_confirmation,
            "#{screen.name}.#{element.name} is destructive but has no confirmation metadata.",
            ["add confirm: \"...\""]
          )
        end
      end

      def finding(severity, code, message, suggestions)
        CompositionFinding.new(
          severity: severity,
          code: code,
          message: message,
          suggestions: suggestions
        )
      end
    end
  end
end
