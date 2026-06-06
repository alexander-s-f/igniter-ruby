# frozen_string_literal: true

module Igniter
  module Hub
    CatalogEntry = Struct.new(
      :name, :title, :version, :description, :bundle_path, :capabilities, :metadata,
      keyword_init: true
    ) do
      def initialize(name:, bundle_path:, title: nil, version: "0.1.0", description: nil, capabilities: [], metadata: {})
        super(
          name: name.to_sym,
          title: title || name.to_s.tr("_", " "),
          version: version.to_s,
          description: description,
          bundle_path: File.expand_path(bundle_path.to_s),
          capabilities: Array(capabilities).map(&:to_sym).freeze,
          metadata: metadata.transform_keys(&:to_sym).freeze
        )
        freeze
      end

      def to_h
        {
          name: name,
          title: title,
          version: version,
          description: description,
          bundle_path: bundle_path,
          capabilities: capabilities,
          metadata: metadata
        }.compact
      end
    end
  end
end
