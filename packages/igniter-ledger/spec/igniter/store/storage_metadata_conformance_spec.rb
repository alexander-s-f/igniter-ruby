# frozen_string_literal: true

require_relative "../../spec_helper"
require "tmpdir"
require "fileutils"

# Storage Metadata Conformance Smoke
#
# Proves that storage_stats and segment_manifest return the same logical
# truth across all access planes:
#
#   Backend → IgniterStore → Protocol::Interpreter → WireEnvelope dispatch
#
# Volatile fields (generated_at) are stripped before comparison.
RSpec.describe "Storage metadata conformance" do
  let(:tmpdir) { Dir.mktmpdir("igniter-conformance-") }

  # Build a store with two stores, sealed + live segments.
  let(:store) do
    s = Igniter::Store.segmented(tmpdir, codec: {
      sensor_readings: :compact_delta,
      agent_signals:   :json_crc32
    })
    # Write to both stores
    5.times { |i|
      s.write(store: :sensor_readings, key: "s#{i}", value: { v: i.to_f, unit: "c" })
    }
    3.times { |i|
      s.write(store: :agent_signals, key: "a#{i}", value: { level: i })
    }
    # Force a sealed segment + new live segment
    s.instance_variable_get(:@backend).checkpoint!
    # Write a few more to the fresh live segment
    2.times { |i|
      s.write(store: :sensor_readings, key: "post#{i}", value: { v: 99.0, unit: "c" })
    }
    s
  end

  let(:backend)  { store.instance_variable_get(:@backend) }
  let(:proto)    { Igniter::Store::Protocol.new(store) }
  let(:wire)     { proto.wire }

  def envelope(op, packet = {})
    {
      protocol:       :igniter_store,
      schema_version: 1,
      request_id:     "req_#{SecureRandom.hex(4)}",
      op:             op,
      packet:         packet
    }
  end

  def strip_volatile(h)
    return h unless h.is_a?(Hash)
    h.reject { |k, _| k.to_s == "generated_at" }
      .transform_values { |v| strip_volatile(v) }
  end

  after do
    store.close rescue nil
    FileUtils.rm_rf(tmpdir)
  end

  # ── Plane agreement ──────────────────────────────────────────────────────────

  describe "storage_stats plane agreement" do
    it "backend equals store (minus generated_at)" do
      b_stats = strip_volatile(backend.storage_stats)
      s_stats = strip_volatile(store.storage_stats)
      expect(s_stats).to eq(b_stats)
    end

    it "store equals protocol (minus generated_at)" do
      s_stats = strip_volatile(store.storage_stats)
      p_stats = strip_volatile(proto.storage_stats)
      expect(p_stats).to eq(s_stats)
    end

    it "protocol equals wire dispatch result (minus generated_at)" do
      p_stats = strip_volatile(proto.storage_stats)
      resp    = wire.dispatch(envelope(:storage_stats))

      expect(resp[:status]).to eq(:ok)
      w_stats = strip_volatile(resp[:result])
      expect(w_stats).to eq(p_stats)
    end
  end

  describe "segment_manifest plane agreement" do
    it "protocol segment_manifest includes segments array" do
      manifest = proto.segment_manifest
      manifest["stores"].each_value do |store_data|
        expect(store_data["segments"]).to be_an(Array)
        expect(store_data["segments"]).not_to be_empty
      end
    end

    it "wire dispatch segment_manifest equals protocol result (minus generated_at)" do
      p_manifest = strip_volatile(proto.segment_manifest)
      resp       = wire.dispatch(envelope(:segment_manifest))

      expect(resp[:status]).to eq(:ok)
      w_manifest = strip_volatile(resp[:result])
      expect(w_manifest).to eq(p_manifest)
    end

    it "segment_manifest has both sealed and live entries" do
      manifest    = proto.segment_manifest(store: :sensor_readings)
      store_data  = manifest["stores"]["sensor_readings"]
      sealed_segs = store_data["segments"].select { |s| s["sealed"] }
      live_segs   = store_data["segments"].reject { |s| s["sealed"] }

      expect(sealed_segs).not_to be_empty
      expect(live_segs).not_to   be_empty
    end
  end

  # ── Store filter consistency ─────────────────────────────────────────────────

  describe "store filter returns exactly one store at every layer" do
    it "backend store filter" do
      stats = backend.storage_stats(store: :sensor_readings)
      expect(stats["stores"].keys).to eq(["sensor_readings"])
    end

    it "store store filter" do
      stats = store.storage_stats(store: :sensor_readings)
      expect(stats["stores"].keys).to eq(["sensor_readings"])
    end

    it "protocol store filter" do
      stats = proto.storage_stats(store: :sensor_readings)
      expect(stats["stores"].keys).to eq(["sensor_readings"])
    end

    it "wire dispatch store filter" do
      resp = wire.dispatch(envelope(:storage_stats, { store: "sensor_readings" }))
      expect(resp[:result]["stores"].keys).to eq(["sensor_readings"])
    end

    it "wire segment_manifest store filter" do
      resp = wire.dispatch(envelope(:segment_manifest, { store: "sensor_readings" }))
      expect(resp[:result]["stores"].keys).to eq(["sensor_readings"])
    end
  end

  # ── metadata_snapshot.storage ────────────────────────────────────────────────

  describe "metadata_snapshot.storage presence" do
    it "segmented backend includes storage: in metadata_snapshot" do
      snap = proto.metadata_snapshot
      expect(snap[:storage]).not_to be_nil
      expect(snap[:storage]["schema_version"]).to eq(1)
      expect(snap[:storage]["stores"].keys).to match_array(%w[sensor_readings agent_signals])
    end

    it "in-memory backend omits storage: from metadata_snapshot" do
      mem_proto = Igniter::Store::Protocol.new
      snap      = mem_proto.metadata_snapshot
      expect(snap).not_to have_key(:storage)
    end

    it "wire metadata_snapshot also includes storage for segmented backend" do
      resp = wire.dispatch(envelope(:metadata_snapshot))
      expect(resp[:status]).to eq(:ok)
      expect(resp[:result][:storage]).not_to be_nil
    end
  end

  # ── Correctness of aggregate values ─────────────────────────────────────────

  describe "storage_stats aggregate correctness" do
    it "total fact_count matches facts written" do
      stats      = proto.storage_stats(store: :sensor_readings)
      store_data = stats["stores"]["sensor_readings"]
      # 5 initial + 2 post-checkpoint = 7 total
      expect(store_data["fact_count"]).to eq(7)
    end

    it "sealed_count + live_count equals segment_count" do
      %w[sensor_readings agent_signals].each do |s|
        data = proto.storage_stats(store: s)["stores"][s]
        expect(data["sealed_count"] + data["live_count"]).to eq(data["segment_count"])
      end
    end

    it "codecs reflect the configured codec per store" do
      readings_codecs = proto.storage_stats(store: :sensor_readings)["stores"]["sensor_readings"]["codecs"]
      signals_codecs  = proto.storage_stats(store: :agent_signals)["stores"]["agent_signals"]["codecs"]

      expect(readings_codecs).to include("compact_delta_zlib")
      expect(signals_codecs).to  include("json_crc32")
    end

    it "byte_size is positive for stores with data" do
      %w[sensor_readings agent_signals].each do |s|
        data = proto.storage_stats(store: s)["stores"][s]
        expect(data["byte_size"]).to be > 0
      end
    end
  end
end
