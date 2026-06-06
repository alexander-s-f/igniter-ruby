# frozen_string_literal: true

module Igniter
  module Application
    class ArtifactReference
      attr_reader :name, :artifact_type, :uri, :summary, :metadata

      def initialize(name:, uri:, artifact_type: :artifact, summary: nil, metadata: {})
        @name = name.to_sym
        @artifact_type = artifact_type.to_sym
        @uri = uri.to_s
        @summary = summary&.to_s
        @metadata = metadata.dup.freeze
        freeze
      end

      def self.from(value)
        return value if value.is_a?(self)

        new(**symbolize_keys(value))
      end

      def to_h
        {
          name: name,
          artifact_type: artifact_type,
          uri: uri,
          summary: summary,
          metadata: metadata.dup
        }
      end

      def self.symbolize_keys(value)
        value.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end
      private_class_method :symbolize_keys
    end
  end
end
