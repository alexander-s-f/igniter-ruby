# frozen_string_literal: true

module Igniter
  module Application
    class MemorySessionStore
      def initialize(entries: {})
        @entries = {}
        @mutex = Mutex.new

        entries.each_value { |entry| write(entry) }
      end

      def write(entry)
        @mutex.synchronize do
          @entries[entry.id] = entry
        end
        entry
      end

      def fetch(id)
        @mutex.synchronize do
          @entries.fetch(id.to_s)
        end
      end

      def entries
        @mutex.synchronize do
          @entries.values.sort_by(&:id)
        end
      end
    end
  end
end
