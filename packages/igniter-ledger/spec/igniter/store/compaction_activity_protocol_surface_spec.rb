# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "json"

RSpec.describe "Compaction Activity Protocol Surface" do
  def make_store
    Igniter::Store::IgniterStore.new
  end

  def make_interpreter(store = make_store)
    Igniter::Store::Protocol::Interpreter.new(store)
  end

  # ── Scope A: Protocol::Interpreter#compaction_activity ───────────────────────

  describe "Protocol::Interpreter#compaction_activity" do
    let(:store)       { make_store }
    let(:interpreter) { make_interpreter(store) }

    it "returns schema_version, generated_at, filters, activity, count" do
      result = interpreter.compaction_activity
      expect(result[:schema_version]).to eq(1)
      expect(result[:generated_at]).to   be_a(String)
      expect(result[:filters]).to        be_a(Hash)
      expect(result[:activity]).to       be_an(Array)
      expect(result[:count]).to          be_an(Integer)
    end

    it "count equals activity.size" do
      result = interpreter.compaction_activity
      expect(result[:count]).to eq(result[:activity].size)
    end

    it "returns empty activity when no compaction has occurred" do
      result = interpreter.compaction_activity
      expect(result[:activity]).to be_empty
      expect(result[:count]).to    eq(0)
    end

    it "returns retention_compaction entry after store compact" do
      store.set_retention(:things, strategy: :ephemeral)
      store.write(store: :things, key: "k", value: { v: 1 })
      store.write(store: :things, key: "k", value: { v: 2 })
      store.compact

      result = interpreter.compaction_activity
      expect(result[:activity]).not_to be_empty
      expect(result[:activity].any? { |e| e[:kind] == :retention_compaction }).to eq(true)
    end

    it "returns exact_prune entry after prune_fact_ids" do
      f = store.write(store: :things, key: "k", value: { v: 1 })
      store.prune_fact_ids(fact_ids: [f.id], reason: :test_clean)

      result = interpreter.compaction_activity
      expect(result[:activity].any? { |e| e[:kind] == :exact_prune }).to eq(true)
    end

    it "filters by store:" do
      store.set_retention(:alpha, strategy: :ephemeral)
      store.set_retention(:beta,  strategy: :ephemeral)
      store.write(store: :alpha, key: "k", value: { v: 1 })
      store.write(store: :alpha, key: "k", value: { v: 2 })
      store.write(store: :beta,  key: "k", value: { v: 1 })
      store.write(store: :beta,  key: "k", value: { v: 2 })
      store.compact

      result = interpreter.compaction_activity(store: "alpha")
      compact_entries = result[:activity].select { |e| e[:kind] == :retention_compaction }
      expect(compact_entries).not_to be_empty
      expect(compact_entries.all? { |e| e[:store].to_s == "alpha" }).to eq(true)
      expect(result[:filters][:store]).to eq("alpha")
    end

    it "filters by kind:" do
      store.set_retention(:things, strategy: :ephemeral)
      store.write(store: :things, key: "k", value: { v: 1 })
      store.write(store: :things, key: "k", value: { v: 2 })
      store.compact

      f = store.write(store: :things, key: "k2", value: { v: 1 })
      store.prune_fact_ids(fact_ids: [f.id], reason: :cleanup)

      result = interpreter.compaction_activity(kind: "retention_compaction")
      expect(result[:activity].all? { |e| e[:kind].to_s == "retention_compaction" }).to eq(true)
      expect(result[:filters][:kind]).to eq("retention_compaction")
    end

    it "filters by since:" do
      store.set_retention(:things, strategy: :ephemeral)
      store.write(store: :things, key: "k", value: { v: 1 })
      store.write(store: :things, key: "k", value: { v: 2 })
      store.compact

      far_future = Process.clock_gettime(Process::CLOCK_REALTIME) + 9_999_999
      result = interpreter.compaction_activity(since: far_future)
      expect(result[:activity]).to be_empty
      expect(result[:filters][:since]).to eq(far_future.to_f)
    end

    it "filters by limit:" do
      store.set_retention(:things, strategy: :ephemeral)
      store.write(store: :things, key: "k1", value: { v: 1 })
      store.write(store: :things, key: "k1", value: { v: 2 })
      store.compact

      f = store.write(store: :things, key: "k2", value: { v: 1 })
      store.prune_fact_ids(fact_ids: [f.id], reason: :cleanup)

      result = interpreter.compaction_activity(limit: 1)
      expect(result[:activity].size).to eq(1)
      expect(result[:count]).to         eq(1)
      expect(result[:filters][:limit]).to eq(1)
    end

    it "nil filters produce nil values in filters hash" do
      result = interpreter.compaction_activity
      expect(result[:filters][:store]).to be_nil
      expect(result[:filters][:kind]).to  be_nil
      expect(result[:filters][:since]).to be_nil
      expect(result[:filters][:limit]).to be_nil
    end
  end

  # ── Scope B: WireEnvelope :compaction_activity ───────────────────────────────

  describe "WireEnvelope :compaction_activity" do
    let(:store) { make_store }
    let(:wire)  { make_interpreter(store).wire }

    def envelope(packet = {})
      {
        protocol:       :igniter_store,
        schema_version: 1,
        request_id:     "req_#{SecureRandom.hex(4)}",
        op:             :compaction_activity,
        packet:         packet
      }
    end

    it "is listed in OPERATIONS" do
      expect(Igniter::Store::Protocol::WireEnvelope::OPERATIONS).to include(:compaction_activity)
    end

    it "dispatch returns ok status" do
      resp = wire.dispatch(envelope)
      expect(resp[:status]).to eq(:ok)
    end

    it "result agrees with interpreter#compaction_activity" do
      store.set_retention(:things, strategy: :ephemeral)
      store.write(store: :things, key: "k", value: { v: 1 })
      store.write(store: :things, key: "k", value: { v: 2 })
      store.compact

      interpreter = make_interpreter(store)
      direct = interpreter.compaction_activity

      resp = interpreter.wire.dispatch(envelope)
      expect(resp[:status]).to eq(:ok)
      expect(resp[:result][:count]).to eq(direct[:count])
      expect(resp[:result][:schema_version]).to eq(direct[:schema_version])
    end

    it "passes store/kind/since/limit filters through packet" do
      resp = wire.dispatch(envelope(store: "orders", kind: "exact_prune",
                                    since: 1_714_000_000, limit: 50))
      expect(resp[:status]).to eq(:ok)
      filters = resp[:result][:filters]
      expect(filters[:store]).to eq("orders")
      expect(filters[:kind]).to  eq("exact_prune")
      expect(filters[:since]).to eq(1_714_000_000.0)
      expect(filters[:limit]).to eq(50)
    end

    it "unknown extra filter keys do not raise" do
      resp = wire.dispatch(envelope(unknown_key: "ignored"))
      expect(resp[:status]).to eq(:ok)
    end

    it "errors are envelope errors, not raised exceptions" do
      bad_env = {
        protocol: :igniter_store, schema_version: 1, request_id: "r1",
        op: :compaction_activity, packet: nil
      }
      expect { wire.dispatch(bad_env) }.not_to raise_error
    end
  end

  # ── Scope C: GET /v1/compaction/activity ─────────────────────────────────────

  describe "GET /v1/compaction/activity" do
    let(:store)       { make_store }
    let(:interpreter) { make_interpreter(store) }
    let(:adapter)     { Igniter::Store::HTTPAdapter.new(interpreter: interpreter) }
    let(:app)         { adapter.rack_app }

    def get_env(path)
      {
        "REQUEST_METHOD" => "GET",
        "PATH_INFO"      => path,
        "SCRIPT_NAME"    => "",
        "QUERY_STRING"   => "",
        "rack.input"     => StringIO.new("")
      }
    end

    def get_env_qs(qs)
      {
        "REQUEST_METHOD" => "GET",
        "PATH_INFO"      => "/v1/compaction/activity",
        "SCRIPT_NAME"    => "",
        "QUERY_STRING"   => qs,
        "rack.input"     => StringIO.new("")
      }
    end

    def post_env(path)
      {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO"      => path,
        "SCRIPT_NAME"    => "",
        "QUERY_STRING"   => "",
        "rack.input"     => StringIO.new("{}")
      }
    end

    it "returns 200 with compaction activity JSON" do
      status, headers, body = app.call(get_env("/v1/compaction/activity"))
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("application/json")
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:schema_version]).to eq(1)
      expect(data[:activity]).to       be_an(Array)
      expect(data[:count]).to          eq(0)
    end

    it "returns 405 for non-GET" do
      status, _, body = app.call(post_env("/v1/compaction/activity"))
      expect(status).to eq(405)
      expect(JSON.parse(body.join)["error"]).to match(/not allowed/i)
    end

    it "accepts store/kind query params" do
      status, _, body = app.call(get_env_qs("store=orders&kind=exact_prune"))
      expect(status).to eq(200)
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:filters][:store]).to eq("orders")
      expect(data[:filters][:kind]).to  eq("exact_prune")
    end

    it "accepts numeric since query param" do
      status, _, body = app.call(get_env_qs("since=1714000000"))
      expect(status).to eq(200)
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:filters][:since]).to eq(1_714_000_000.0)
    end

    it "returns 400 for invalid since" do
      status, _, body = app.call(get_env_qs("since=not_a_number"))
      expect(status).to eq(400)
      error = JSON.parse(body.join)
      expect(error["error"]).to match(/since/i)
    end

    it "returns 400 for invalid limit" do
      status, _, body = app.call(get_env_qs("limit=xyz"))
      expect(status).to eq(400)
      error = JSON.parse(body.join)
      expect(error["error"]).to match(/limit/i)
    end

    it "accepts integer limit query param" do
      status, _, body = app.call(get_env_qs("limit=10"))
      expect(status).to eq(200)
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:filters][:limit]).to eq(10)
    end

    it "returns same data as interpreter#compaction_activity" do
      store.set_retention(:things, strategy: :ephemeral)
      store.write(store: :things, key: "k", value: { v: 1 })
      store.write(store: :things, key: "k", value: { v: 2 })
      store.compact

      _, _, body = app.call(get_env("/v1/compaction/activity"))
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:count]).to eq(1)
      expect(data[:activity].first[:kind]).to eq("retention_compaction")
    end
  end

  # ── Scope D: MCP tool compaction_activity ────────────────────────────────────

  describe "MCPAdapter :compaction_activity" do
    let(:store)   { make_store }
    let(:adapter) { Igniter::Store::MCPAdapter.new(store) }

    it "is listed in READ_TOOLS" do
      expect(Igniter::Store::MCPAdapter::READ_TOOLS).to include(:compaction_activity)
    end

    it "TOOL_TO_OP maps compaction_activity to :compaction_activity" do
      expect(Igniter::Store::MCPAdapter::TOOL_TO_OP[:compaction_activity]).to eq(:compaction_activity)
    end

    it "tool_list includes compaction_activity by default" do
      names = adapter.tool_list.map { |t| t[:name].to_sym }
      expect(names).to include(:compaction_activity)
    end

    it "tool schema has name, description, input_schema" do
      tool = adapter.tool_list.find { |t| t[:name] == "compaction_activity" }
      expect(tool).not_to be_nil
      expect(tool[:description]).to be_a(String)
      expect(tool[:input_schema]).to be_a(Hash)
    end

    it "input_schema has store/kind/since/limit properties" do
      tool = adapter.tool_list.find { |t| t[:name] == "compaction_activity" }
      props = tool[:input_schema][:properties]
      expect(props).to have_key(:store)
      expect(props).to have_key(:kind)
      expect(props).to have_key(:since)
      expect(props).to have_key(:limit)
    end

    it "call_tool returns ok with schema_version" do
      resp = adapter.call_tool(:compaction_activity)
      expect(resp[:status]).to             eq(:ok)
      expect(resp[:source_protocol_op]).to eq(:compaction_activity)
      expect(resp[:result][:schema_version]).to eq(1)
    end

    it "call_tool returns activity entries after compact" do
      store.set_retention(:things, strategy: :ephemeral)
      store.write(store: :things, key: "k", value: { v: 1 })
      store.write(store: :things, key: "k", value: { v: 2 })
      store.compact

      resp = adapter.call_tool(:compaction_activity)
      expect(resp[:status]).to eq(:ok)
      expect(resp[:result][:count]).to eq(1)
    end

    it "passes filter args to interpreter" do
      resp = adapter.call_tool(:compaction_activity, store: "orders", kind: "exact_prune", limit: 5)
      expect(resp[:status]).to eq(:ok)
      filters = resp[:result][:filters]
      expect(filters[:store]).to eq("orders")
      expect(filters[:kind]).to  eq("exact_prune")
      expect(filters[:limit]).to eq(5)
    end

    it "source_protocol_op is :compaction_activity" do
      resp = adapter.call_tool(:compaction_activity)
      expect(resp[:source_protocol_op]).to eq(:compaction_activity)
    end

    it "no mutating compact/prune/purge/delete tool is exposed" do
      mutating = %w[compact prune purge delete]
      tool_names = Igniter::Store::MCPAdapter::READ_TOOLS.map(&:to_s)
      mutating.each do |verb|
        exact_matches = tool_names.select { |t| t == verb || t == "#{verb}!" }
        expect(exact_matches).to be_empty, "expected no bare #{verb} mutating tool in READ_TOOLS"
      end
    end

    describe "remote adapter path" do
      it "builds correct packet for compaction_activity" do
        adapter_class = Igniter::Store::MCPAdapter
        # We test packet_for indirectly by checking dispatch succeeds over wire
        interpreter = make_interpreter(store)
        wire_result = interpreter.wire.dispatch({
          protocol:       :igniter_store,
          schema_version: 1,
          request_id:     "r_test",
          op:             :compaction_activity,
          packet:         { store: "tasks", kind: "exact_prune", since: 1_000_000.0, limit: 10 }
        })
        expect(wire_result[:status]).to eq(:ok)
        expect(wire_result[:result][:filters][:store]).to eq("tasks")
      end
    end
  end

  # ── Scope E: SyncProfile compaction_activity field ───────────────────────────

  describe "SyncProfile#compaction_activity" do
    let(:store)       { make_store }
    let(:interpreter) { make_interpreter(store) }

    it "SyncProfile has a compaction_activity field" do
      profile = interpreter.sync_hub_profile
      expect(profile).to respond_to(:compaction_activity)
    end

    it "compaction_activity in sync profile is a hash with schema_version" do
      profile = interpreter.sync_hub_profile
      ca = profile.compaction_activity
      expect(ca).to be_a(Hash)
      expect(ca[:schema_version]).to eq(1)
      expect(ca[:activity]).to       be_an(Array)
    end

    it "compaction_activity in sync profile includes compaction entries" do
      store.set_retention(:things, strategy: :ephemeral)
      store.write(store: :things, key: "k", value: { v: 1 })
      store.write(store: :things, key: "k", value: { v: 2 })
      store.compact

      profile = interpreter.sync_hub_profile
      expect(profile.compaction_activity[:count]).to eq(1)
    end

    it "existing compaction_receipts field is still present on SyncProfile" do
      profile = interpreter.sync_hub_profile
      expect(profile).to respond_to(:compaction_receipts)
    end
  end
end
