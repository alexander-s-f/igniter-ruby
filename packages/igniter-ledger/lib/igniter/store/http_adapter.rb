# frozen_string_literal: true

require "rack"
require "json"

module Igniter
  module Store
    # HTTP transport adapter for the Igniter Store Open Protocol.
    #
    # Exposes Protocol::Interpreter over HTTP via a Rack-compatible app.
    # The canonical endpoint is POST /v1/dispatch which accepts and returns
    # a WireEnvelope JSON object.
    #
    # Usage:
    #   adapter = HTTPAdapter.new(interpreter: interpreter, port: 7300)
    #   adapter.rack_app   # → Rack-compatible, mountable in any server
    #   adapter.start      # → foreground via Puma (dev dep)
    #   adapter.start_async / adapter.stop
    class HTTPAdapter
      module ResponseHelper
        private

        def json_response(status, data)
          body = JSON.generate(data)
          [status, { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s }, [body]]
        end

        def method_not_allowed
          json_response(405, { error: "Method not allowed" })
        end
      end

      class DispatchHandler
        include ResponseHelper

        def initialize(interpreter)
          @interpreter = interpreter
        end

        def call(env)
          return method_not_allowed unless env["REQUEST_METHOD"] == "POST"

          body = env["rack.input"].read
          begin
            envelope = JSON.parse(body, symbolize_names: true)
          rescue JSON::ParserError => e
            return json_response(400, { error: "Invalid JSON: #{e.message}" })
          end

          json_response(200, @interpreter.wire.dispatch(envelope))
        end
      end

      class HealthHandler
        include ResponseHelper

        def initialize(health_provider: nil)
          @health_provider = health_provider
        end

        def call(env)
          return method_not_allowed unless env["REQUEST_METHOD"] == "GET"

          health = @health_provider ? @health_provider.call : { protocol: :igniter_store, schema_version: 1, status: :ready }
          json_response(200, health)
        end
      end

      class MetadataHandler
        include ResponseHelper

        def initialize(interpreter)
          @interpreter = interpreter
        end

        def call(env)
          return method_not_allowed unless env["REQUEST_METHOD"] == "GET"

          json_response(200, @interpreter.metadata_snapshot)
        end
      end

      # Returns the canonical observability snapshot at GET /v1/status.
      # When +status_provider+ is given (e.g. StoreServer#observability_snapshot),
      # it is called to produce the full server+storage shape.
      # Otherwise falls back to the interpreter's storage-level snapshot.
      class StatusHandler
        include ResponseHelper

        def initialize(interpreter:, status_provider: nil)
          @interpreter     = interpreter
          @status_provider = status_provider
        end

        def call(env)
          return method_not_allowed unless env["REQUEST_METHOD"] == "GET"

          data = @status_provider ? @status_provider.call : @interpreter.observability_snapshot
          json_response(200, data)
        end
      end

      # Readiness probe: 200 when ready to serve traffic, 503 otherwise (draining,
      # stopped, or initialising).  +ready_provider+ must return truthy/falsy.
      class ReadyHandler
        include ResponseHelper

        def initialize(ready_provider: nil)
          @ready_provider = ready_provider
        end

        def call(env)
          return method_not_allowed unless env["REQUEST_METHOD"] == "GET"

          ready = @ready_provider ? @ready_provider.call : true
          if ready
            json_response(200, { status: "ready" })
          else
            json_response(503, { status: "unavailable" })
          end
        end
      end

      # Returns the metrics sub-hash from the observability snapshot.
      class MetricsHandler
        include ResponseHelper

        def initialize(metrics_provider: nil)
          @metrics_provider = metrics_provider
        end

        def call(env)
          return method_not_allowed unless env["REQUEST_METHOD"] == "GET"

          data = @metrics_provider ? @metrics_provider.call : {}
          json_response(200, data)
        end
      end

      # Streaming body for SSE responses.
      #
      # Emits retained catch-up events from +replay_events+, then blocks on a
      # live subscription to the ChangefeedBuffer until #close is called.
      #
      # SSE frame format per event:
      #   id: <sequence>
      #   event: fact_committed
      #   data: <ChangeEvent#to_h JSON>
      #   (blank line)
      #
      # #close is safe to call from any thread — it pushes a sentinel to unblock
      # the live delivery loop so the subscription handle is released cleanly.
      class SseBody
        SSE_SENTINEL = :__sse_close

        def initialize(buf, replay_events, sub_stores)
          @buf           = buf
          @replay_events = replay_events
          @sub_stores    = sub_stores
          @queue         = nil
        end

        def each
          @replay_events.each { |e| yield sse_frame(e) }

          @queue  = Queue.new
          handle  = @buf.subscribe(stores: @sub_stores) { |e| @queue << e }

          begin
            loop do
              event = @queue.pop
              break if event.equal?(SSE_SENTINEL)
              yield sse_frame(event)
            end
          rescue IOError, Errno::EPIPE
            nil
          ensure
            handle&.close
          end
        end

        def close
          @queue&.push(SSE_SENTINEL)
        end

        private

        def sse_frame(event)
          "id: #{event.cursor[:sequence]}\nevent: fact_committed\ndata: #{JSON.generate(event.to_h)}\n\n"
        end
      end

      # GET /v1/events — Server-Sent Events transport over ChangefeedBuffer.
      #
      # Protocol:
      # 1. Replay retained events (catch-up).
      # 2. Subscribe for live events.
      #
      # Cursor input (both optional):
      #   Last-Event-ID: N  →  replay after sequence N (browser auto-reconnect)
      #   ?cursor=N         →  same, for simple clients / tests
      #
      # Store filtering (optional):
      #   ?store=tasks             →  single store
      #   ?stores=tasks,reminders  →  multiple stores
      #   (none)                   →  all stores (wildcard)
      #
      # Error: when the requested cursor is too old (gap due to ring overflow),
      # returns 409 JSON instead of starting the stream.
      class SseEventsHandler
        include ResponseHelper

        def initialize(changefeed_provider:)
          @changefeed_provider = changefeed_provider
        end

        def call(env)
          return method_not_allowed unless env["REQUEST_METHOD"] == "GET"

          buf = @changefeed_provider&.call
          return json_response(503, { error: "SSE events endpoint not configured" }) unless buf

          cursor = parse_sse_cursor(env)
          stores = parse_sse_stores(env)

          replay_result = buf.replay(
            cursor: cursor,
            stores: stores.empty? ? nil : stores
          )

          if replay_result[:status] == :cursor_too_old
            return json_response(409, {
              status:        "cursor_too_old",
              oldest_cursor: replay_result[:oldest_cursor],
              newest_cursor: replay_result[:newest_cursor],
              dropped_total: replay_result[:dropped_total]
            })
          end

          body = SseBody.new(buf, replay_result[:events], stores)
          [200, sse_headers, body]
        end

        private

        def sse_headers
          {
            "Content-Type"      => "text/event-stream; charset=utf-8",
            "Cache-Control"     => "no-cache",
            "X-Accel-Buffering" => "no"
          }
        end

        def parse_sse_cursor(env)
          last_id = env["HTTP_LAST_EVENT_ID"]
          if last_id && !last_id.empty?
            seq = Integer(last_id, 10) rescue nil
            return { sequence: seq } if seq
          end
          query    = Rack::Utils.parse_query(env["QUERY_STRING"] || "")
          cursor_s = query["cursor"]
          if cursor_s && !cursor_s.empty?
            seq = Integer(cursor_s, 10) rescue nil
            return { sequence: seq } if seq
          end
          nil
        end

        def parse_sse_stores(env)
          query    = Rack::Utils.parse_query(env["QUERY_STRING"] || "")
          stores_s = query["stores"] || query["store"] || ""
          stores_s.split(",").map(&:strip).reject(&:empty?)
        end
      end

      # GET /v1/compaction/activity — normalized compaction lifecycle activity.
      #
      # Query params (all optional):
      #   ?store=orders
      #   ?kind=exact_prune
      #   ?since=1714000000
      #   ?limit=50
      #
      # Returns same JSON shape as Protocol::Interpreter#compaction_activity.
      # Non-GET → 405.  Invalid numeric since/limit → 400.
      class CompactionActivityHandler
        include ResponseHelper

        def initialize(interpreter)
          @interpreter = interpreter
        end

        def call(env)
          return method_not_allowed unless env["REQUEST_METHOD"] == "GET"

          query = Rack::Utils.parse_query(env["QUERY_STRING"] || "")

          store = query["store"]
          kind  = query["kind"]

          since_raw = query["since"]
          if since_raw
            since = Float(since_raw) rescue nil
            return json_response(400, { error: "Invalid numeric value for 'since': #{since_raw.inspect}" }) if since.nil?
          end

          limit_raw = query["limit"]
          if limit_raw
            limit = Integer(limit_raw, 10) rescue nil
            return json_response(400, { error: "Invalid integer value for 'limit': #{limit_raw.inspect}" }) if limit.nil?
          end

          result = @interpreter.compaction_activity(
            store: store,
            kind:  kind,
            since: since,
            limit: limit
          )
          json_response(200, result)
        end
      end

      # Returns recent structured events from the server event ring buffer.
      class EventsRecentHandler
        include ResponseHelper

        def initialize(events_provider: nil)
          @events_provider = events_provider
        end

        def call(env)
          return method_not_allowed unless env["REQUEST_METHOD"] == "GET"

          events = @events_provider ? @events_provider.call : []
          json_response(200, { events: events, count: events.size })
        end
      end

      # ── Adapter ──────────────────────────────────────────────────────────────

      def initialize(interpreter:, port: 7300, host: "0.0.0.0",
                     health_provider: nil, status_provider: nil,
                     ready_provider: nil, metrics_provider: nil, events_provider: nil,
                     changefeed_provider: nil)
        @interpreter         = interpreter
        @port                = port
        @host                = host
        @health_provider     = health_provider
        @status_provider     = status_provider
        @ready_provider      = ready_provider
        @metrics_provider    = metrics_provider
        @events_provider     = events_provider
        @changefeed_provider = changefeed_provider
        @puma                = nil
        @thread              = nil
      end

      # Returns a Rack-compatible app mountable in any Rack server.
      def rack_app
        interp = @interpreter
        hp     = @health_provider
        sp     = @status_provider
        rp     = @ready_provider
        mp     = @metrics_provider
        ep     = @events_provider
        cp     = @changefeed_provider
        not_found = ->(env) {
          body = JSON.generate({ error: "Not found: #{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}" })
          [404, { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s }, [body]]
        }

        Rack::Builder.new do
          map "/v1/dispatch"            do run DispatchHandler.new(interp) end
          map "/v1/health"              do run HealthHandler.new(health_provider: hp) end
          map "/v1/status"              do run StatusHandler.new(interpreter: interp, status_provider: sp) end
          map "/v1/ready"               do run ReadyHandler.new(ready_provider: rp) end
          map "/v1/metrics"             do run MetricsHandler.new(metrics_provider: mp) end
          # /v1/events/recent must precede /v1/events to avoid prefix shadowing.
          map "/v1/events/recent"       do run EventsRecentHandler.new(events_provider: ep) end
          map "/v1/events"              do run SseEventsHandler.new(changefeed_provider: cp) end
          map "/v1/metadata"            do run MetadataHandler.new(interp) end
          map "/v1/compaction/activity" do run CompactionActivityHandler.new(interp) end
          run not_found
        end
      end

      # Starts the server in the current thread (blocks). Requires puma.
      def start
        require "puma"
        @puma = Puma::Server.new(rack_app)
        @puma.add_tcp_listener(@host, @port)
        @puma.run.join
      end

      # Starts in a background thread. Returns self.
      def start_async
        @thread = Thread.new { start }
        sleep 0.05
        self
      end

      def stop
        @puma&.stop(true) rescue nil
        @thread&.join(2) rescue nil
        self
      end

      def bind_address
        "#{@host}:#{@port}"
      end
    end
  end
end
