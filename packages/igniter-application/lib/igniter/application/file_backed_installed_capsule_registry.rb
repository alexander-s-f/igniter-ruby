# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Igniter
  module Application
    class FileBackedInstalledCapsuleRegistry
      attr_reader :root

      def self.build(root:)
        new(root: root)
      end

      def initialize(root:)
        @root = File.expand_path(root.to_s)
        freeze
      end

      def record(name, receipt:, source: nil, version: nil, metadata: {})
        installed_at = Time.now.utc.iso8601
        entry = InstalledCapsuleEntry.new(
          name: name,
          receipt: receipt,
          source: source,
          version: version,
          metadata: metadata,
          installed_at: installed_at
        )
        FileUtils.mkdir_p(registry_dir)
        File.write(entry_path(name), "#{JSON.pretty_generate(entry.to_h)}\n")
        append_history(entry, installed_at: installed_at)
        entry
      end

      def entries
        Dir.glob(File.join(registry_dir, "*.json")).sort.map do |path|
          payload = JSON.parse(File.read(path), symbolize_names: true)
          InstalledCapsuleEntry.new(
            name: payload.fetch(:name),
            receipt: payload.fetch(:receipt),
            source: payload[:source],
            version: payload[:version],
            metadata: payload.fetch(:metadata, {}),
            installed_at: payload[:installed_at]
          )
        end.freeze
      end

      def fetch(name)
        entries.find { |entry| entry.name == name.to_sym } || raise(KeyError, "unknown installed capsule #{name.inspect}")
      end

      def installed?(name)
        fetch(name).installed?
      rescue KeyError
        false
      end

      def history(name = nil)
        paths = if name
                  Dir.glob(File.join(history_dir, "#{safe_key(name)}--*.json"))
                else
                  Dir.glob(File.join(history_dir, "*.json"))
                end
        paths.sort.map do |path|
          JSON.parse(File.read(path), symbolize_names: true)
        end.freeze
      end

      def to_h
        {
          root: root,
          entries: entries.map(&:to_h),
          history_count: history.length
        }
      end

      private

      def registry_dir
        File.join(root, "installed-capsules")
      end

      def entry_path(name)
        File.join(registry_dir, "#{safe_key(name)}.json")
      end

      def append_history(entry, installed_at:)
        FileUtils.mkdir_p(history_dir)
        sequence = next_history_sequence(entry.name)
        event = {
          event_id: history_event_id(entry, sequence),
          event_type: :installed_capsule_recorded,
          capsule: entry.name,
          sequence: sequence,
          status: entry.status,
          source: entry.source,
          version: entry.version,
          complete: entry.complete,
          valid: entry.valid,
          committed: entry.committed,
          receipt: entry.receipt,
          metadata: entry.metadata,
          recorded_at: installed_at
        }.compact
        File.write(history_path(entry, sequence), "#{JSON.pretty_generate(event)}\n")
      end

      def history_dir
        File.join(root, "installed-capsule-history")
      end

      def history_path(entry, sequence)
        File.join(history_dir, "#{safe_key(entry.name)}--#{sequence.to_s.rjust(6, "0")}.json")
      end

      def history_event_id(entry, sequence)
        "installed-capsule:#{safe_key(entry.name)}:#{sequence}"
      end

      def next_history_sequence(name)
        history(name).map { |event| event.fetch(:sequence, 0).to_i }.max.to_i + 1
      end

      def safe_key(value)
        value.to_s.gsub(/[^a-zA-Z0-9_.-]/, "_")
      end
    end
  end
end
