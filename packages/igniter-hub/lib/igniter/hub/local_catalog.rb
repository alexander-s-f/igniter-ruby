# frozen_string_literal: true

module Igniter
  module Hub
    class LocalCatalog
      attr_reader :path, :entries

      def self.load(path)
        payload = JSON.parse(File.read(path), symbolize_names: true)
        root = File.dirname(File.expand_path(path.to_s))
        entries = Array(payload.fetch(:entries, [])).map do |entry|
          build_entry(entry, root: root)
        end
        new(path: path, entries: entries)
      end

      def self.build_entry(entry, root:)
        CatalogEntry.new(
          name: entry.fetch(:name),
          title: entry[:title],
          version: entry.fetch(:version, "0.1.0"),
          description: entry[:description],
          bundle_path: File.expand_path(entry.fetch(:bundle_path), root),
          capabilities: entry.fetch(:capabilities, []),
          metadata: entry.fetch(:metadata, {})
        )
      end

      def initialize(path:, entries:)
        @path = File.expand_path(path.to_s)
        @entries = entries.freeze
        freeze
      end

      def names
        entries.map(&:name).sort
      end

      def fetch(name)
        entries.find { |entry| entry.name == name.to_sym } || raise(KeyError, "unknown hub capsule #{name.inspect}")
      end

      def to_h
        {
          path: path,
          entries: entries.map(&:to_h)
        }
      end
    end
  end
end
