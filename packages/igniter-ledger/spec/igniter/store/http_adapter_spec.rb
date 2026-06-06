# frozen_string_literal: true

require_relative "../../spec_helper"
require "stringio"

RSpec.describe Igniter::Store::HTTPAdapter do
  def make_interpreter
    Igniter::Store::Protocol::Interpreter.new(Igniter::Store::IgniterStore.new)
  end

  def make_adapter(interpreter = make_interpreter)
    Igniter::Store::HTTPAdapter.new(interpreter: interpreter)
  end

  def dispatch_env(envelope, path: "/v1/dispatch")
    {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO"      => path,
      "SCRIPT_NAME"    => "",
      "rack.input"     => StringIO.new(JSON.generate(envelope))
    }
  end

  def get_env(path)
    {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO"      => path,
      "SCRIPT_NAME"    => "",
      "rack.input"     => StringIO.new("")
    }
  end

  def base_envelope(op, packet = {})
    {
      protocol:       "igniter_store",
      schema_version: 1,
      request_id:     "test-#{SecureRandom.hex(4)}",
      op:             op,
      packet:         packet
    }
  end

  let(:interpreter) { make_interpreter }
  let(:adapter)     { make_adapter(interpreter) }
  let(:app)         { adapter.rack_app }

  # ── /v1/health ──────────────────────────────────────────────────────────────

  describe "GET /v1/health" do
    it "returns 200 with ready status" do
      status, headers, body = app.call(get_env("/v1/health"))

      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("application/json")
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:status]).to eq("ready")
      expect(data[:protocol]).to eq("igniter_store")
      expect(data[:schema_version]).to eq(1)
    end

    it "returns 405 for POST /v1/health" do
      env = dispatch_env({}, path: "/v1/health")
      status, _, body = app.call(env)
      expect(status).to eq(405)
      expect(JSON.parse(body.join)["error"]).to match(/not allowed/i)
    end
  end

  # ── /v1/metadata ────────────────────────────────────────────────────────────

  describe "GET /v1/metadata" do
    it "returns 200 with schema_version key" do
      status, headers, body = app.call(get_env("/v1/metadata"))

      expect(status).to eq(200)
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:schema_version]).to eq(1)
      expect(data).to have_key(:stores)
      expect(data).to have_key(:histories)
    end

    it "returns 405 for POST /v1/metadata" do
      env = dispatch_env({}, path: "/v1/metadata")
      status, _, _ = app.call(env)
      expect(status).to eq(405)
    end

    it "reflects registered store names" do
      interpreter.register(
        schema_version: 1, kind: :store, name: :tasks, key: :id,
        fields: [{ name: :title, type: :string }]
      )
      _, _, body = app.call(get_env("/v1/metadata"))
      data = JSON.parse(body.join, symbolize_names: true)
      store_names = data[:stores].keys.map(&:to_s)
      expect(store_names).to include("tasks")
    end
  end

  # ── /v1/dispatch ────────────────────────────────────────────────────────────

  describe "POST /v1/dispatch" do
    it "returns 405 for GET /v1/dispatch" do
      status, _, body = app.call(get_env("/v1/dispatch"))
      expect(status).to eq(405)
    end

    it "returns 400 for non-JSON body" do
      env = {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO"      => "/v1/dispatch",
        "SCRIPT_NAME"    => "",
        "rack.input"     => StringIO.new("not json!!!")
      }
      status, _, body = app.call(env)
      expect(status).to eq(400)
      expect(JSON.parse(body.join)["error"]).to match(/invalid json/i)
    end

    it "returns 200 with error status for unknown op" do
      env = dispatch_env(base_envelope("nonexistent_op"))
      status, _, body = app.call(env)
      expect(status).to eq(200)
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:status].to_s).to eq("error")
    end

    it "returns 200 with error status for unknown protocol" do
      env = dispatch_env(
        base_envelope("metadata_snapshot").merge(protocol: "wrong_protocol")
      )
      status, _, body = app.call(env)
      expect(status).to eq(200)
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:status].to_s).to eq("error")
    end

    context "smoke: register → write → read → query → metadata_snapshot" do
      it "round-trips through all major operations" do
        # register_descriptor
        reg_env = dispatch_env(base_envelope("register_descriptor", {
          schema_version: 1, kind: :store, name: :tasks, key: :id,
          fields: [{ name: :title, type: :string }, { name: :done, type: :boolean }]
        }))
        _, _, body = app.call(reg_env)
        reg = JSON.parse(body.join, symbolize_names: true)
        expect(reg[:status].to_s).to eq("ok")

        # write
        write_env = dispatch_env(base_envelope("write", {
          store: :tasks, key: "t1", value: { title: "Buy milk", done: false }
        }))
        _, _, body = app.call(write_env)
        write_resp = JSON.parse(body.join, symbolize_names: true)
        expect(write_resp[:status].to_s).to eq("ok")

        # read
        read_env = dispatch_env(base_envelope("read", { store: :tasks, key: "t1" }))
        _, _, body = app.call(read_env)
        read_resp = JSON.parse(body.join, symbolize_names: true)
        expect(read_resp[:status].to_s).to eq("ok")
        expect(read_resp[:result][:found]).to be true
        expect(read_resp[:result][:value][:title]).to eq("Buy milk")

        # query
        query_env = dispatch_env(base_envelope("query", {
          store: :tasks, where: { done: false }
        }))
        _, _, body = app.call(query_env)
        query_resp = JSON.parse(body.join, symbolize_names: true)
        expect(query_resp[:status].to_s).to eq("ok")
        expect(query_resp[:result][:count]).to eq(1)

        # metadata_snapshot
        meta_env = dispatch_env(base_envelope("metadata_snapshot"))
        _, _, body = app.call(meta_env)
        meta_resp = JSON.parse(body.join, symbolize_names: true)
        expect(meta_resp[:status].to_s).to eq("ok")
        expect(meta_resp[:result][:schema_version]).to eq(1)
      end
    end

    context "sync_hub_profile" do
      it "returns a sync profile through dispatch" do
        env = dispatch_env(base_envelope("sync_hub_profile", {}))
        _, _, body = app.call(env)
        resp = JSON.parse(body.join, symbolize_names: true)
        expect(resp[:status].to_s).to eq("ok")
        result = resp[:result]
        expect(result[:kind].to_s).to eq("sync_hub_profile")
        expect(result[:schema_version]).to eq(1)
        expect(result).to have_key(:facts)
      end
    end
  end

  # ── unknown path ────────────────────────────────────────────────────────────

  describe "unknown path" do
    it "returns 404 for GET /unknown" do
      status, _, body = app.call(get_env("/unknown"))
      expect(status).to eq(404)
      expect(JSON.parse(body.join)["error"]).to match(/not found/i)
    end

    it "returns 404 for POST /other" do
      env = dispatch_env({}, path: "/other")
      status, _, _ = app.call(env)
      expect(status).to eq(404)
    end
  end

  # ── bind_address ────────────────────────────────────────────────────────────

  describe "#bind_address" do
    it "returns host:port string" do
      a = Igniter::Store::HTTPAdapter.new(interpreter: make_interpreter, port: 7300, host: "0.0.0.0")
      expect(a.bind_address).to eq("0.0.0.0:7300")
    end
  end

  # ── GET /v1/events — SSE transport ──────────────────────────────────────────

  describe "GET /v1/events (SSE)" do
    # ── Helpers ──────────────────────────────────────────────────────────────

    def make_sse_app(buf = nil)
      buf ||= Igniter::Store::ChangefeedBuffer.new
      adapter = Igniter::Store::HTTPAdapter.new(
        interpreter:         make_interpreter,
        changefeed_provider: -> { buf }
      )
      [adapter.rack_app, buf]
    end

    def sse_env(query: nil, last_event_id: nil)
      env = {
        "REQUEST_METHOD" => "GET",
        "PATH_INFO"      => "/v1/events",
        "SCRIPT_NAME"    => "",
        "QUERY_STRING"   => query.to_s,
        "rack.input"     => StringIO.new("")
      }
      env["HTTP_LAST_EVENT_ID"] = last_event_id.to_s if last_event_id
      env
    end

    # Iterate the SSE body in a background thread, let it drain for +wait+
    # seconds, then close cleanly. Returns collected chunks.
    def drain_sse(body, wait: 0.08)
      chunks = []
      t = Thread.new { body.each { |c| chunks << c } }
      sleep wait
      body.close
      t.join(1)
      chunks
    end

    def parse_frames(chunks)
      chunks.join.split("\n\n").map(&:strip).reject(&:empty?).map do |block|
        result = {}
        block.each_line do |line|
          line = line.chomp
          result[:id]    = Integer(line.sub("id: ", ""), 10) if line.start_with?("id: ")
          result[:event] = line.sub("event: ", "")          if line.start_with?("event: ")
          if line.start_with?("data: ")
            result[:data] = JSON.parse(line.sub("data: ", ""), symbolize_names: true)
          end
        end
        result
      end.reject(&:empty?)
    end

    def emit_fact(buf, store: :tasks, key: "k")
      buf.emit(Igniter::Store::Fact.build(store: store, key: key, value: {}))
    end

    # ── Method enforcement ────────────────────────────────────────────────────

    it "returns 405 for POST /v1/events" do
      app, = make_sse_app
      env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/v1/events",
              "SCRIPT_NAME" => "", "QUERY_STRING" => "", "rack.input" => StringIO.new("") }
      status, _, _ = app.call(env)
      expect(status).to eq(405)
    end

    it "returns 503 when no changefeed_provider is configured" do
      adapter = Igniter::Store::HTTPAdapter.new(interpreter: make_interpreter)
      status, _, body = adapter.rack_app.call(sse_env)
      expect(status).to eq(503)
      expect(JSON.parse(body.join, symbolize_names: true)[:error]).to match(/not configured/i)
    end

    # ── Response shape ────────────────────────────────────────────────────────

    it "returns 200 with text/event-stream content type" do
      app, = make_sse_app
      status, headers, body = app.call(sse_env)
      body.close
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to include("text/event-stream")
    end

    # ── Replay catch-up ───────────────────────────────────────────────────────

    it "replays retained events before live events" do
      app, buf = make_sse_app
      3.times { |i| emit_fact(buf, key: "k#{i}") }

      _, _, body = app.call(sse_env)
      frames = parse_frames(drain_sse(body))

      expect(frames.size).to eq(3)
      seqs = frames.map { |f| f[:id] }
      expect(seqs).to eq([1, 2, 3])
    end

    it "SSE event field is fact_committed" do
      app, buf = make_sse_app
      emit_fact(buf)

      _, _, body = app.call(sse_env)
      frames = parse_frames(drain_sse(body))

      expect(frames.first[:event]).to eq("fact_committed")
    end

    it "SSE id equals the cursor sequence" do
      app, buf = make_sse_app
      2.times { |i| emit_fact(buf, key: "k#{i}") }

      _, _, body = app.call(sse_env)
      frames = parse_frames(drain_sse(body))

      expect(frames.map { |f| f[:id] }).to eq([1, 2])
    end

    it "SSE data contains ChangeEvent#to_h fields and does NOT include :fact" do
      app, buf = make_sse_app
      emit_fact(buf, store: :tasks, key: "t1")

      _, _, body = app.call(sse_env)
      frames = parse_frames(drain_sse(body))

      data = frames.first[:data]
      expect(data).to have_key(:schema_version)
      expect(data).to have_key(:cursor)
      expect(data).to have_key(:fact_id)
      expect(data).not_to have_key(:fact)
    end

    # ── Cursor input ──────────────────────────────────────────────────────────

    it "Last-Event-ID header resumes after that sequence" do
      app, buf = make_sse_app
      5.times { |i| emit_fact(buf, key: "k#{i}") }

      _, _, body = app.call(sse_env(last_event_id: 3))
      frames = parse_frames(drain_sse(body))

      seqs = frames.map { |f| f[:id] }
      expect(seqs).to eq([4, 5])
    end

    it "?cursor=N query param resumes after sequence N" do
      app, buf = make_sse_app
      4.times { |i| emit_fact(buf, key: "k#{i}") }

      _, _, body = app.call(sse_env(query: "cursor=2"))
      frames = parse_frames(drain_sse(body))

      seqs = frames.map { |f| f[:id] }
      expect(seqs).to eq([3, 4])
    end

    it "Last-Event-ID takes precedence over ?cursor param" do
      app, buf = make_sse_app
      4.times { |i| emit_fact(buf, key: "k#{i}") }

      _, _, body = app.call(sse_env(query: "cursor=1", last_event_id: 3))
      frames = parse_frames(drain_sse(body))

      seqs = frames.map { |f| f[:id] }
      expect(seqs).to eq([4])
    end

    it "no cursor returns all retained events" do
      app, buf = make_sse_app
      3.times { |i| emit_fact(buf, key: "k#{i}") }

      _, _, body = app.call(sse_env)
      frames = parse_frames(drain_sse(body))

      expect(frames.size).to eq(3)
    end

    # ── cursor_too_old ────────────────────────────────────────────────────────

    it "returns 409 JSON when cursor is too old (ring overflow gap)" do
      buf = Igniter::Store::ChangefeedBuffer.new(max_size: 2)
      5.times { |i| emit_fact(buf, key: "k#{i}") }
      # Ring has [4,5], oldest=4; cursor=1 → gap (need 2,3 which are gone)
      app, = make_sse_app(buf)

      status, headers, body = app.call(sse_env(last_event_id: 1))

      expect(status).to eq(409)
      expect(headers["Content-Type"]).to eq("application/json")
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:status]).to            eq("cursor_too_old")
      expect(data[:oldest_cursor]).to     include(:sequence)
      expect(data[:newest_cursor]).to     include(:sequence)
      expect(data[:dropped_total]).to     be > 0
    end

    it "does NOT return 409 when cursor is oldest_seq - 1 (no gap)" do
      buf = Igniter::Store::ChangefeedBuffer.new(max_size: 3)
      5.times { |i| emit_fact(buf, key: "k#{i}") }
      # Ring has [3,4,5], oldest=3; cursor=2 → no gap
      app, = make_sse_app(buf)

      status, _, body = app.call(sse_env(last_event_id: 2))
      frames = parse_frames(drain_sse(body))

      expect(status).to eq(200)
      expect(frames.map { |f| f[:id] }).to eq([3, 4, 5])
    end

    # ── Store filtering ───────────────────────────────────────────────────────

    it "?store=tasks filters replay to the given store" do
      app, buf = make_sse_app
      emit_fact(buf, store: :tasks,     key: "t1")
      emit_fact(buf, store: :reminders, key: "r1")
      emit_fact(buf, store: :tasks,     key: "t2")

      _, _, body = app.call(sse_env(query: "store=tasks"))
      frames = parse_frames(drain_sse(body))

      stores = frames.map { |f| f[:data][:store] }
      expect(stores).to eq(%w[tasks tasks])
    end

    it "?stores=tasks,reminders filters replay to multiple stores" do
      app, buf = make_sse_app
      emit_fact(buf, store: :tasks,     key: "t1")
      emit_fact(buf, store: :reminders, key: "r1")
      emit_fact(buf, store: :other,     key: "o1")

      _, _, body = app.call(sse_env(query: "stores=tasks,reminders"))
      frames = parse_frames(drain_sse(body))

      stores = frames.map { |f| f[:data][:store] }.sort
      expect(stores).to eq(%w[reminders tasks])
    end

    it "no store param returns all stores" do
      app, buf = make_sse_app
      emit_fact(buf, store: :tasks)
      emit_fact(buf, store: :reminders)

      _, _, body = app.call(sse_env)
      frames = parse_frames(drain_sse(body))

      expect(frames.size).to eq(2)
    end

    # ── Live delivery ─────────────────────────────────────────────────────────

    it "delivers a live event emitted after replay completes" do
      app, buf = make_sse_app

      # One replay event already in buffer
      emit_fact(buf, key: "replay1")

      _, _, body = app.call(sse_env)
      chunks = []
      t = Thread.new { body.each { |c| chunks << c } }
      sleep 0.05  # let replay drain

      # Emit a live event while subscriber is connected
      emit_fact(buf, key: "live1")
      sleep 0.05

      body.close
      t.join(1)

      frames = parse_frames(chunks)
      expect(frames.size).to eq(2)
      last_key = frames.last[:data][:key]
      expect(last_key).to eq("live1")
    end

    it "live store filter applied to live events" do
      app, buf = make_sse_app

      _, _, body = app.call(sse_env(query: "store=tasks"))
      chunks = []
      t = Thread.new { body.each { |c| chunks << c } }
      sleep 0.04

      emit_fact(buf, store: :tasks,     key: "t1")
      emit_fact(buf, store: :reminders, key: "r1")
      sleep 0.05

      body.close
      t.join(1)

      frames = parse_frames(chunks)
      expect(frames.size).to eq(1)
      expect(frames.first[:data][:store]).to eq("tasks")
    end

    # ── Disconnect / close ────────────────────────────────────────────────────

    it "subscription handle releases on body.close" do
      app, buf = make_sse_app

      _, _, body = app.call(sse_env)
      t = Thread.new { body.each { } }
      sleep 0.04
      expect(buf.subscriber_count).to eq(1)

      body.close
      t.join(1)
      sleep 0.02  # let ensure block run
      expect(buf.subscriber_count).to eq(0)
    end

    # ── /v1/events/recent is not shadowed ─────────────────────────────────────

    it "GET /v1/events/recent still returns the events ring, not SSE" do
      adapter = Igniter::Store::HTTPAdapter.new(
        interpreter:    make_interpreter,
        events_provider: -> { [{ type: "server_start", ts: "2026-05-03T00:00:00" }] },
        changefeed_provider: -> { Igniter::Store::ChangefeedBuffer.new }
      )
      status, headers, body = adapter.rack_app.call(get_env("/v1/events/recent"))
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("application/json")
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:count]).to eq(1)
    end
  end
end
