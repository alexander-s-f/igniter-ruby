# frozen_string_literal: true

require "spec_helper"
require "igniter/server"

RSpec.describe Igniter::Server::HttpServer do
  wait_readable_error = Class.new(IOError) do
    include IO::WaitReadable
  end

  let(:config) { Igniter::Server::Config.new }
  subject(:server) { described_class.new(config) }

  describe "#accept_connection" do
    it "returns nil when the server socket is closed during select" do
      tcp_server = instance_double(TCPServer)

      server.instance_variable_set(:@tcp_server, tcp_server)
      server.instance_variable_set(:@running, true)

      allow(tcp_server).to receive(:accept_nonblock).and_raise(wait_readable_error.new)
      allow(IO).to receive(:select).with([tcp_server], nil, nil, 0.5).and_raise(Errno::EBADF.new)

      expect(server.send(:accept_connection)).to be_nil
    end

    it "returns nil without waiting when the server is already stopping" do
      tcp_server = instance_double(TCPServer)

      server.instance_variable_set(:@tcp_server, tcp_server)
      server.instance_variable_set(:@running, false)

      allow(tcp_server).to receive(:accept_nonblock).and_raise(wait_readable_error.new)
      expect(IO).not_to receive(:select)

      expect(server.send(:accept_connection)).to be_nil
    end
  end

  describe "#graceful_stop" do
    it "closes the socket and marks the server as stopped without logging in trap-sensitive path" do
      tcp_server = instance_double(TCPServer)
      logger = instance_double(Igniter::Server::ServerLogger)

      server.instance_variable_set(:@tcp_server, tcp_server)
      server.instance_variable_set(:@logger, logger)
      server.instance_variable_set(:@running, true)

      expect(tcp_server).to receive(:close)
      expect(logger).not_to receive(:info)

      server.graceful_stop

      expect(server.instance_variable_get(:@running)).to be(false)
      expect(server.instance_variable_get(:@shutdown_mode)).to eq(:graceful)
    end
  end

  describe "#stop" do
    it "closes the listener and marks the server for immediate shutdown" do
      tcp_server = instance_double(TCPServer)

      server.instance_variable_set(:@tcp_server, tcp_server)
      server.instance_variable_set(:@running, true)

      expect(tcp_server).to receive(:close)

      server.stop

      expect(server.instance_variable_get(:@running)).to be(false)
      expect(server.instance_variable_get(:@shutdown_mode)).to eq(:immediate)
    end
  end

  describe "#close_active_connections" do
    it "closes tracked client sockets outside trap context" do
      client_socket = instance_double(TCPSocket)

      server.instance_variable_set(:@connections, { client_socket.object_id => client_socket })

      expect(client_socket).to receive(:close)

      server.send(:close_active_connections)
    end
  end

  describe "#write_response" do
    it "preserves custom response headers such as redirect location" do
      socket = StringIO.new

      server.send(
        :write_response,
        socket,
        {
          status: 303,
          body: "",
          headers: {
            "Content-Type" => "text/html; charset=utf-8",
            "Location" => "/?note_created=1"
          }
        }
      )

      payload = socket.string

      expect(payload).to include("HTTP/1.1 303 See Other")
      expect(payload).to include("Content-Type: text/html; charset=utf-8")
      expect(payload).to include("Location: /?note_created=1")
    end
  end

  describe "#start" do
    it "runs after_start hooks after the listener binds" do
      tcp_server = instance_double(TCPServer)
      logger = instance_double(Igniter::Server::ServerLogger, info: nil, error: nil)
      seen = []

      config.port = 4667
      config.after_start_hooks << lambda do |config:, server:|
        seen << [config.port, server.class.name]
        server.stop
      end

      server.instance_variable_set(:@logger, logger)

      allow(TCPServer).to receive(:new).with(config.host, config.port).and_return(tcp_server)
      allow(server).to receive(:trap)
      allow(server).to receive(:accept_connection).and_return(nil)
      allow(tcp_server).to receive(:close)

      server.start

      expect(seen).to eq([[4667, "Igniter::Server::HttpServer"]])
    end
  end
end
