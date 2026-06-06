# frozen_string_literal: true

module Igniter
  module Store
    # Configuration value object for StoreServer.
    #
    # All fields have safe defaults — a zero-argument ServerConfig starts an
    # in-memory server on 127.0.0.1:7400 with info-level logging to stdout.
    #
    # Usage:
    #   config = Igniter::Store::ServerConfig.new(
    #     host:          "0.0.0.0",
    #     port:          7400,
    #     backend:       :file,
    #     path:          "/var/lib/igniter/store.wal",
    #     log_level:     :info,
    #     pid_file:      "/var/run/igniter-ledger.pid",
    #     drain_timeout: 10
    #   )
    class ServerConfig
      DEFAULTS = {
        host:            "127.0.0.1",
        port:            7400,
        transport:       :tcp,
        backend:         :memory,
        path:            nil,
        log_io:          $stdout,
        log_level:       :info,
        pid_file:        nil,
        drain_timeout:   5,    # seconds to wait for active connections before force-stop
        max_connections: nil,  # nil = unlimited
        changefeed:      {}    # ChangefeedBuffer constructor kwargs; {} = all defaults
      }.freeze

      attr_reader(*DEFAULTS.keys)

      def initialize(**opts)
        unknown = opts.keys - DEFAULTS.keys
        raise ArgumentError, "Unknown ServerConfig keys: #{unknown.inspect}" if unknown.any?

        DEFAULTS.merge(opts).each { |k, v| instance_variable_set(:"@#{k}", v) }
      end

      # Bind address string for the server socket.
      # TCP: "host:port". Unix: the socket path (stored in @host).
      def bind_address
        transport == :unix ? host : "#{host}:#{port}"
      end

      def to_h
        DEFAULTS.keys.to_h { |k| [k, public_send(k)] }
      end
    end
  end
end
