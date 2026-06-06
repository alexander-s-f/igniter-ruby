# frozen_string_literal: true

module Igniter
  module Cluster
    class CapabilityDefinition
      attr_reader :name, :traits, :description, :labels, :metadata

      def initialize(name:, traits: [], description: nil, labels: {}, metadata: {})
        @name = name.to_sym
        @traits = Array(traits).map(&:to_sym).uniq.sort.freeze
        @description = description
        @labels = normalize_labels(labels)
        @metadata = metadata.dup.freeze
        freeze
      end

      def tagged?(name, value = nil)
        return labels.key?(name.to_sym) if value.nil?

        labels[name.to_sym] == value
      end

      def to_h
        {
          name: name,
          traits: traits.dup,
          description: description,
          labels: labels.dup,
          metadata: metadata.dup
        }
      end

      private

      def normalize_labels(labels)
        labels.each_with_object({}) do |(key, value), memo|
          memo[key.to_sym] = value
        end.freeze
      end
    end
  end
end
