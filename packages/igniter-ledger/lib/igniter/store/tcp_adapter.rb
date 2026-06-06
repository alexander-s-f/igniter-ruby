# frozen_string_literal: true

require "socket"
require "json"
require_relative "wire_protocol"

module Igniter
  module Store
    # TCP transport adapter for the Igniter Store Open Protocol.
    #
    # Exposes Protocol::Interpreter over a framed TCP (or Unix socket) connection
    # using the same WireProtocol CRC32 framing as the legacy StoreServer path.
    # Each request frame carries a WireEnvelope JSON object; each response frame
    # carries the WireEnvelope response JSON object.
    #
    # This is the new envelope dispatch path (default port 7401). The legacy
    # StoreServer path (port 7400) is separate and unchanged.
    #
    # Usage:
    #   adapter = TCPAdapter.new(interpreter: interpreter, port: 7401)
    #   adapter.start_async
    #   adapter.wait_until_ready
    #   adapter.stop
    class TCPAdapter
      include WireProtocol

      def initialize(interpreter:, port: 7401, host: "127.0.0.1", transport: :tcp)
        @interpreter    = interpreter
        @port           = port
        @host           = host
        @transport      = transport
        @stopped        = false
        @threads        = []
        @threads_mutex  = Mutex.new
        @ready_mutex    = Mutex.new
        @ready_cond     = ConditionVariable.new
        @ready          = false
        @server         = build_server
        # Socket is bound during initialize — signal ready immediately so that
        # wait_until_ready is race-free even before start is called.
        signal_ready
      end

      # Runs the accept loop in the current thread (blocks until #stop).
      def start
        until @stopped
          begin
            socket = @server.accept
          rescue IOError, Errno::EBADF
            break
          end
          t = Thread.new(socket) { |s| handle_client(s) }
          @threads_mutex.synchronize { @threads << t }
        end
      end

      # Starts the accept loop in a background thread. Returns self.
      def start_async
        @thread = Thread.new do
          Thread.current.abort_on_exception = false
          start
        end
        wait_until_ready
        self
      end

      # Blocks until the server socket is bound and ready.
      def wait_until_ready(timeout: 2)
        @ready_mutex.synchronize do
          deadline = Time.now + timeout
          until @ready
            remaining = deadline - Time.now
            raise "TCPAdapter did not become ready within #{timeout}s" if remaining <= 0
            @ready_cond.wait(@ready_mutex, remaining)
          end
        end
        self
      end

      def stop
        @stopped = true
        @server&.close rescue nil
        @thread&.join(2) rescue nil
        @threads_mutex.synchronize { @threads.each { |t| t.join(1) rescue nil } }
        self
      end

      def bind_address
        @transport == :unix ? @host : "#{@host}:#{@port}"
      end

      private

      def build_server
        case @transport
        when :tcp  then TCPServer.new(@host, @port)
        when :unix then UNIXServer.new(@host)
        else raise ArgumentError, "Unknown transport: #{@transport.inspect}. Use :tcp or :unix"
        end
      end

      def signal_ready
        @ready_mutex.synchronize { @ready = true; @ready_cond.broadcast }
      end

      def handle_client(socket)
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true) rescue nil
        loop do
          body = read_frame(socket)
          break unless body

          envelope = JSON.parse(body, symbolize_names: true)
          result   = @interpreter.wire.dispatch(envelope)
          socket.write(encode_frame(JSON.generate(result)))
        end
      rescue IOError, Errno::ECONNRESET, Errno::EPIPE
        # client disconnected cleanly
      rescue => e
        # unexpected error — log and close
        $stderr.puts "TCPAdapter: client error: #{e.class}: #{e.message}" rescue nil
      ensure
        socket.close rescue nil
        @threads_mutex.synchronize { @threads.delete(Thread.current) }
      end
    end
  end
end
