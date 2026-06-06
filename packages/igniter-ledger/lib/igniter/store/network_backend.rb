# frozen_string_literal: true

require "socket"
require "json"
require_relative "wire_protocol"

module Igniter
  module Store
    # NetworkBackend — client-side backend that proxies write_fact / replay /
    # write_snapshot over a TCP or Unix socket connection to a StoreServer.
    #
    # The wire protocol is CRC32-framed JSON (same framing as the WAL file format).
    # Each request is a single frame; the server replies with a single frame.
    #
    # Usage (via Companion::Store):
    #   store = Igniter::Companion::Store.new(
    #     backend:   :network,
    #     address:   "127.0.0.1:7400",
    #     transport: :tcp           # default; or :unix for Unix domain sockets
    #   )
    #
    # Direct usage:
    #   nb = Igniter::Store::NetworkBackend.new(address: "127.0.0.1:7400")
    #
    # Reactive push subscription (separate connection, background thread):
    #   handle = nb.subscribe(stores: [:tasks]) { |fact| puts fact.key }
    #   handle.close   # unsubscribes cleanly
    class NetworkBackend
      include WireProtocol

      class NetworkError < StandardError; end

      # Handle returned by #subscribe. Call #close to unsubscribe.
      class Subscription
        include WireProtocol

        def initialize(socket, thread)
          @socket = socket
          @thread = thread
        end

        def close
          begin
            @socket.write(encode_frame(JSON.generate({ op: "close" })))
          rescue IOError, Errno::EPIPE, Errno::ECONNRESET
            nil
          end
          @socket.close rescue nil
          @thread.kill rescue nil
        end
      end

      def initialize(address:, transport: :tcp)
        @address   = address
        @transport = transport
        @mutex     = Mutex.new
        @socket    = connect
      end

      def write_fact(fact)
        rpc("write_fact", fact: fact.to_h)
        nil
      end

      # Returns an Array<Fact> from the server's durable store.
      def replay
        response = rpc("replay")
        (response[:facts] || []).map { |h| decode_fact(h) }
      end

      # Sends all +facts+ to the server for snapshot storage.
      # No-op on the server side if the server backend does not support snapshots.
      def write_snapshot(facts)
        rpc("write_snapshot", facts: facts.map(&:to_h))
        nil
      end

      # Opens a dedicated second connection for push events and registers a handler.
      # The main RPC connection is unaffected.
      # Returns a Subscription handle; call handle.close to unsubscribe.
      def subscribe(stores:, &callback)
        raise ArgumentError, "subscribe requires a block" unless callback

        sub_socket = connect
        stores_s   = Array(stores).map(&:to_s)
        sub_socket.write(encode_frame(JSON.generate({ op: "subscribe", stores: stores_s })))

        body = read_frame(sub_socket)
        raise NetworkError, "Subscribe: server closed connection" unless body
        resp = JSON.parse(body, symbolize_names: true)
        raise NetworkError, resp[:error] unless resp[:ok]

        thread = Thread.new(sub_socket) do |sock|
          Thread.current.abort_on_exception = false
          loop do
            body = read_frame(sock)
            break unless body
            event = JSON.parse(body, symbolize_names: true)
            next unless event[:event] == "fact_written"
            fact = decode_fact(event[:fact])
            callback.call(fact) rescue nil
          end
        rescue IOError, Errno::ECONNRESET, Errno::EPIPE, Errno::EBADF
          nil
        ensure
          sock.close rescue nil
        end

        Subscription.new(sub_socket, thread)
      end

      def close
        @mutex.synchronize do
          send_frame({ op: "close" })
          read_frame(@socket)  # drain the server's { ok: true } so socket can close cleanly (FIN not RST)
        rescue IOError, Errno::EPIPE, Errno::ECONNRESET
          nil
        ensure
          @socket.close rescue nil
        end
      end

      private

      def connect
        case @transport
        when :tcp
          host, port = @address.split(":")
          s = TCPSocket.new(host, Integer(port))
          s.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
          s
        when :unix
          UNIXSocket.new(@address)
        else
          raise ArgumentError, "Unknown transport: #{@transport.inspect}. Use :tcp or :unix"
        end
      end

      def rpc(op, **params)
        @mutex.synchronize do
          send_frame(params.merge(op: op))
          body = read_frame(@socket)
          raise NetworkError, "Connection closed by server" unless body
          response = JSON.parse(body, symbolize_names: true)
          raise NetworkError, response[:error] unless response[:ok]
          response
        end
      end

      def send_frame(payload)
        @socket.write(encode_frame(JSON.generate(payload)))
      end

      def decode_fact(h)
        Fact.from_h(h)
      end
    end
  end
end
