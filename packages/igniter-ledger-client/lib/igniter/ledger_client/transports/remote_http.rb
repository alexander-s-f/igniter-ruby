# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "../subscription"

module Igniter
  module LedgerClient
    module Transports
      class RemoteHTTP
        attr_reader :uri, :events_uri, :open_timeout, :read_timeout

        def initialize(endpoint, events_url: nil, open_timeout: 1.0, read_timeout: 2.0, write_timeout: nil, headers: {})
          @uri = normalize_endpoint(endpoint)
          @events_uri = normalize_events_endpoint(events_url)
          @open_timeout = open_timeout
          @read_timeout = read_timeout
          @write_timeout = write_timeout
          @headers = headers
        end

        def dispatch(envelope)
          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/json"
          @headers.each { |key, value| request[key.to_s] = value }
          request.body = JSON.generate(envelope)

          response = http.request(request)
          raise TransportError, "ledger HTTP #{uri} returned #{response.code}" unless response.code.to_i.between?(200, 299)

          JSON.parse(response.body, symbolize_names: true)
        rescue JSON::ParserError => e
          raise TransportError, "invalid ledger HTTP response: #{e.message}"
        end

        def subscribe(stores:, cursor: nil, &block)
          raise ArgumentError, "subscribe requires a block" unless block

          http_client = nil
          thread = nil
          subscription = Subscription.new do
            http_client&.finish if http_client&.started?
            thread&.join(1) unless Thread.current.equal?(thread)
          rescue IOError, SystemCallError
            nil
          end

          thread = Thread.new do
            stream_uri = events_stream_uri(stores: stores, cursor: cursor)
            request = Net::HTTP::Get.new(stream_uri)
            request["Accept"] = "text/event-stream"
            @headers.each { |key, value| request[key.to_s] = value }
            http_client = http_for(stream_uri)
            http_client.request(request) do |response|
              raise TransportError, "ledger SSE #{stream_uri} returned #{response.code}" unless response.code.to_i.between?(200, 299)

              read_sse(response, subscription, &block)
            end
          rescue StandardError => e
            subscription.error = e unless subscription&.closed?
          ensure
            subscription&.close unless subscription&.closed?
          end
          subscription
        end

        private

        def http
          http_for(uri)
        end

        def http_for(target_uri)
          Net::HTTP.new(target_uri.host, target_uri.port).tap do |client|
            client.use_ssl = target_uri.scheme == "https"
            client.open_timeout = open_timeout if open_timeout
            client.read_timeout = read_timeout if read_timeout
            client.write_timeout = @write_timeout if @write_timeout && client.respond_to?(:write_timeout=)
          end
        end

        def normalize_endpoint(endpoint)
          parsed = URI(endpoint.to_s)
          parsed.path = "/v1/dispatch" if parsed.path.nil? || parsed.path.empty? || parsed.path == "/"
          parsed
        end

        def normalize_events_endpoint(events_url)
          return derive_events_uri unless events_url

          parsed = URI(events_url.to_s)
          parsed.path = "/v1/events" if parsed.path.nil? || parsed.path.empty? || parsed.path == "/"
          parsed
        end

        def derive_events_uri
          uri.dup.tap do |parsed|
            parsed.path = parsed.path.end_with?("/v1/dispatch") ? parsed.path.sub(%r{/v1/dispatch\z}, "/v1/events") : "/v1/events"
          end
        end

        def events_stream_uri(stores:, cursor:)
          events_uri.dup.tap do |parsed|
            params = URI.decode_www_form(parsed.query.to_s)
            store_names = Array(stores).map(&:to_s).reject(&:empty?)
            params << ["stores", store_names.join(",")] unless store_names.empty?
            sequence = cursor_sequence(cursor)
            params << ["cursor", sequence.to_s] if sequence
            parsed.query = params.empty? ? nil : URI.encode_www_form(params)
          end
        end

        def cursor_sequence(cursor)
          return nil unless cursor

          data = cursor.respond_to?(:to_h) ? cursor.to_h.transform_keys(&:to_sym) : { sequence: cursor }
          data[:sequence]
        end

        def read_sse(response, subscription, &block)
          buffer = +""
          response.read_body do |chunk|
            break if subscription&.closed?

            buffer << chunk
            while (frame = next_sse_frame(buffer))
              event = parse_sse_frame(frame)
              block.call(event) if event
            end
          end
        end

        def next_sse_frame(buffer)
          idx = buffer.index("\n\n")
          sep_len = 2
          unless idx
            idx = buffer.index("\r\n\r\n")
            sep_len = 4
          end
          return nil unless idx

          buffer.slice!(0, idx + sep_len)
        end

        def parse_sse_frame(frame)
          event_id = nil
          data_lines = []

          frame.each_line do |line|
            line = line.chomp
            event_id = line.sub("id: ", "") if line.start_with?("id: ")
            data_lines << line.sub("data: ", "") if line.start_with?("data: ")
          end
          return nil if data_lines.empty?

          data = JSON.parse(data_lines.join("\n"), symbolize_names: true)
          data[:sequence] ||= event_id.to_i if event_id
          data
        rescue JSON::ParserError => e
          raise TransportError, "invalid ledger SSE event: #{e.message}"
        end
      end
    end
  end
end
