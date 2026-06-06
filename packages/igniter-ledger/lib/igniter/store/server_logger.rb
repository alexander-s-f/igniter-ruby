# frozen_string_literal: true

require "json"
require "time"

module Igniter
  module Store
    # Thread-safe structured logger for StoreServer.
    #
    # Each line is written as:
    #   [2026-04-30T12:34:56.789] INFO  message
    #
    # Structured events are written as:
    #   [EVENT] {"event":"server_start","ts":"2026-04-30T12:34:56.789Z",...}
    #
    # Pass log_io: nil to silence all output (useful in tests).
    class ServerLogger
      LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }.freeze

      def initialize(io = $stdout, level = :info)
        @io    = io
        @min   = LEVELS.fetch(level, 1)
        @mutex = Mutex.new
      end

      def debug(msg) = log(:debug, msg)
      def info(msg)  = log(:info,  msg)
      def warn(msg)  = log(:warn,  msg)
      def error(msg) = log(:error, msg)

      # Emits a structured JSON event line:
      #   [EVENT] {"event":"connection_open","ts":"...","connection_id":"..."}
      #
      # +level:+ controls the minimum log level for this event (default :info).
      # Pass level: :debug for high-frequency per-request events.
      def event(type, level: :info, **attrs)
        return if LEVELS.fetch(level, 1) < @min
        return unless @io

        payload = { event: type, ts: Time.now.iso8601(3) }.merge(attrs)
        @mutex.synchronize { @io.write("[EVENT] #{JSON.generate(payload)}\n") }
      rescue IOError, JSON::GeneratorError
        nil
      end

      def level
        LEVELS.key(@min)
      end

      private

      def log(level, msg)
        return if LEVELS[level] < @min
        return unless @io

        ts = Time.now.strftime("%Y-%m-%dT%H:%M:%S.%3N")
        line = "[#{ts}] #{level.to_s.upcase.ljust(5)} #{msg}\n"
        @mutex.synchronize { @io.write(line) }
      rescue IOError
        nil
      end
    end
  end
end
