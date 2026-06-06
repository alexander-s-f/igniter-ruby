# frozen_string_literal: true

module Igniter
  module Web
    class FlowSurfaceProjection
      attr_reader :surface, :declaration, :feature, :metadata

      def self.project(surface, declaration:, feature: nil, metadata: {})
        new(surface: surface, declaration: declaration, feature: feature, metadata: metadata).to_h
      end

      def initialize(surface:, declaration:, feature: nil, metadata: {})
        @surface = normalize_surface(surface)
        @declaration = normalize_hash(declaration)
        @feature = feature.nil? ? nil : normalize_hash(feature)
        @metadata = metadata.dup.freeze
        freeze
      end

      def to_h
        {
          status: status,
          surface: surface_identity,
          flow: flow_identity,
          feature: feature_identity,
          pending_inputs: comparison(:pending_inputs),
          pending_actions: comparison(:pending_actions),
          relationships: relationships,
          metadata: metadata.dup
        }.compact
      end

      private

      def normalize_surface(value)
        return value.to_h if value.respond_to?(:to_h)

        normalize_hash(value)
      end

      def normalize_hash(value)
        value.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end

      def surface_identity
        {
          name: surface[:name],
          path: surface[:path]
        }.compact
      end

      def flow_identity
        {
          name: declaration[:name],
          initial_status: declaration[:initial_status],
          current_step: declaration[:current_step],
          purpose: declaration[:purpose]
        }.compact
      end

      def feature_identity
        return nil if feature.nil?

        {
          name: feature[:name],
          flows: Array(feature[:flows]),
          surfaces: Array(feature[:surfaces])
        }
      end

      def comparison(kind)
        surface_names = names_from(surface_interactions(kind))
        declaration_names = names_from(Array(declaration[kind]))

        {
          surface: surface_names,
          declaration: declaration_names,
          matched: surface_names & declaration_names,
          missing_in_surface: declaration_names - surface_names,
          extra_in_surface: surface_names - declaration_names
        }
      end

      def surface_interactions(kind)
        interactions = normalize_hash(surface.fetch(:interactions, {}))
        Array(interactions[kind])
      end

      def names_from(entries)
        entries.map do |entry|
          source = entry.respond_to?(:to_h) ? entry.to_h : entry
          source.fetch(:name).to_sym
        end
      end

      def relationships
        {
          declaration_references_surface: references?(declaration[:surfaces], surface[:name]),
          feature_references_surface: feature && references?(feature[:surfaces], surface[:name]),
          feature_references_flow: feature && references?(feature[:flows], declaration[:name])
        }.compact
      end

      def references?(entries, name)
        return false if name.nil?

        Array(entries).map(&:to_sym).include?(name.to_sym)
      end

      def status
        input_comparison = comparison(:pending_inputs)
        action_comparison = comparison(:pending_actions)
        aligned = input_comparison.fetch(:missing_in_surface).empty? &&
                  action_comparison.fetch(:missing_in_surface).empty? &&
                  relationships.fetch(:declaration_references_surface, false)

        aligned ? :aligned : :attention
      end
    end
  end
end
