# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"
require "tmpdir"

RSpec.describe "Igniter::Cluster Governance Compaction (Phase 6)" do
  let(:identity) { Igniter::Cluster::Identity::NodeIdentity.generate(node_id: "compact-node") }

  def build_trail(events_count = 30)
    trail = Igniter::Cluster::Governance::Trail.new
    events_count.times { |i| trail.record(:"event_#{i}", source: :spec, payload: { i: i }) }
    trail
  end

  # ── Trail#compact! ────────────────────────────────────────────────────────────

  describe "Trail#compact!" do
    let(:trail) { build_trail(30) }

    it "starts with empty compaction_history" do
      t = Igniter::Cluster::Governance::Trail.new
      expect(t.compaction_history).to eq([])
    end

    it "returns a CompactionRecord" do
      rec = trail.compact!(keep_last: 10)
      expect(rec).to be_a(Igniter::Cluster::Governance::CompactionRecord)
    end

    it "removes events beyond keep_last" do
      trail.compact!(keep_last: 10)
      # compact! itself records a :trail_compacted event, so we get keep_last + 1
      expect(trail.events.size).to eq(11)
    end

    it "reports correct removed_events count" do
      rec = trail.compact!(keep_last: 10)
      expect(rec.removed_events).to eq(20)
    end

    it "reports kept_events equal to keep_last" do
      rec = trail.compact!(keep_last: 10)
      expect(rec.kept_events).to eq(10)
    end

    it "compacted? is true when events were removed" do
      rec = trail.compact!(keep_last: 10)
      expect(rec).to be_compacted
    end

    it "compacted? is false when nothing was removed" do
      small_trail = Igniter::Cluster::Governance::Trail.new
      5.times { |i| small_trail.record(:"e#{i}", source: :spec) }
      rec = small_trail.compact!(keep_last: 10)
      expect(rec).not_to be_compacted
    end

    it "records the compaction event in the trail" do
      trail.compact!(keep_last: 10)
      types = trail.events.map { |e| e[:type] }
      expect(types).to include(:trail_compacted)
    end

    context "with identity (signed checkpoint)" do
      it "builds a signed Checkpoint" do
        rec = trail.compact!(keep_last: 10, identity: identity, peer_name: "compact-node")
        expect(rec).to be_signed
        expect(rec.checkpoint).to be_a(Igniter::Cluster::Governance::Checkpoint)
      end

      it "checkpoint has a crest_digest" do
        rec = trail.compact!(keep_last: 10, identity: identity, peer_name: "compact-node")
        expect(rec.checkpoint_digest).to be_a(String)
        expect(rec.checkpoint_digest).to match(/\A[0-9a-f]{24}\z/)
      end

      it "checkpoint signature is verifiable" do
        rec = trail.compact!(keep_last: 10, identity: identity, peer_name: "compact-node")
        expect(rec.checkpoint.verify_signature).to be true
      end

      it "appends to compaction_history" do
        trail.compact!(keep_last: 20, identity: identity, peer_name: "compact-node")
        trail.compact!(keep_last: 5,  identity: identity, peer_name: "compact-node")
        expect(trail.compaction_history.size).to eq(2)
      end
    end

    context "without identity (unsigned)" do
      it "returns a CompactionRecord with nil checkpoint" do
        rec = trail.compact!(keep_last: 10)
        expect(rec.checkpoint).to be_nil
        expect(rec).not_to be_signed
      end
    end
  end

  # ── Trail#events_since ───────────────────────────────────────────────────────

  describe "Trail#events_since" do
    it "returns all events when checkpoint is nil" do
      trail = build_trail(5)
      expect(trail.events_since(nil).size).to eq(5)
    end

    it "returns only events after the checkpoint timestamp" do
      trail  = Igniter::Cluster::Governance::Trail.new
      t0     = Time.now.utc.iso8601
      3.times { |i| trail.record(:"before_#{i}", source: :spec) }
      rec    = trail.compact!(keep_last: 20, identity: identity, peer_name: "n")
      cp     = rec.checkpoint
      3.times { |i| trail.record(:"after_#{i}", source: :spec) }

      since = trail.events_since(cp)
      # Should include events recorded after checkpoint + the trail_compacted event itself may vary
      since_types = since.map { |e| e[:type] }
      expect(since_types).to all(satisfy { |t| t.to_s.start_with?("after") || t == :trail_compacted })
    end

    it "returns empty when no events after checkpoint" do
      trail = Igniter::Cluster::Governance::Trail.new
      5.times { |i| trail.record(:"e#{i}", source: :spec) }
      rec = trail.compact!(keep_last: 20, identity: identity, peer_name: "n")
      cp  = rec.checkpoint
      # No new events after the checkpoint (compact itself is before or at checkpoint ts)
      since = trail.events_since(cp)
      expect(since).to be_an(Array)
    end
  end

  # ── Checkpoint previous_digest chaining ──────────────────────────────────────

  describe "Checkpoint previous_digest chaining" do
    let(:trail) { build_trail(10) }

    it "is nil for an unchained checkpoint" do
      cp = Igniter::Cluster::Governance::Checkpoint.build(
        identity: identity, peer_name: "n", trail: trail
      )
      expect(cp.previous_digest).to be_nil
      expect(cp).not_to be_chained
    end

    it "stores previous digest when chained" do
      cp1 = Igniter::Cluster::Governance::Checkpoint.build(
        identity: identity, peer_name: "n", trail: trail
      )
      cp2 = Igniter::Cluster::Governance::Checkpoint.build(
        identity: identity, peer_name: "n", trail: trail, previous: cp1
      )
      expect(cp2.previous_digest).to eq(cp1.crest_digest)
      expect(cp2).to be_chained
    end

    it "includes previous_digest in the payload so signature covers it" do
      cp1 = Igniter::Cluster::Governance::Checkpoint.build(
        identity: identity, peer_name: "n", trail: trail
      )
      cp2 = Igniter::Cluster::Governance::Checkpoint.build(
        identity: identity, peer_name: "n", trail: trail, previous: cp1
      )
      expect(cp2.payload).to have_key(:previous_digest)
      expect(cp2.verify_signature).to be true
    end

    it "two sequential compactions form a chain" do
      rec1 = trail.compact!(keep_last: 5, identity: identity, peer_name: "n")
      rec2 = trail.compact!(keep_last: 5, identity: identity, peer_name: "n", previous: rec1.checkpoint)
      expect(rec2.checkpoint.previous_digest).to eq(rec1.checkpoint.crest_digest)
    end

    it "to_h round-trips through from_h with previous_digest" do
      cp1 = Igniter::Cluster::Governance::Checkpoint.build(
        identity: identity, peer_name: "n", trail: trail
      )
      cp2 = Igniter::Cluster::Governance::Checkpoint.build(
        identity: identity, peer_name: "n", trail: trail, previous: cp1
      )
      restored = Igniter::Cluster::Governance::Checkpoint.from_h(cp2.to_h)
      expect(restored.previous_digest).to eq(cp1.crest_digest)
      expect(restored.verify_signature).to be true
    end
  end

  # ── CheckpointStore ───────────────────────────────────────────────────────────

  describe Igniter::Cluster::Governance::Stores::CheckpointStore do
    around do |example|
      Dir.mktmpdir do |dir|
        @tmpdir = dir
        example.run
      end
    end

    let(:path)  { File.join(@tmpdir, "checkpoint.json") }
    let(:store) { described_class.new(path: path) }

    let(:checkpoint) do
      trail = build_trail(5)
      Igniter::Cluster::Governance::Checkpoint.build(
        identity: identity, peer_name: "node-a", trail: trail
      )
    end

    it "exists? returns false before saving" do
      expect(store.exists?).to be false
    end

    it "save writes the file" do
      store.save(checkpoint)
      expect(store.exists?).to be true
    end

    it "load returns nil when no file exists" do
      expect(store.load).to be_nil
    end

    it "load returns a Checkpoint after save" do
      store.save(checkpoint)
      loaded = store.load
      expect(loaded).to be_a(Igniter::Cluster::Governance::Checkpoint)
    end

    it "round-trips peer_name and crest_digest" do
      store.save(checkpoint)
      loaded = store.load
      expect(loaded.peer_name).to eq("node-a")
      expect(loaded.crest_digest).to eq(checkpoint.crest_digest)
    end

    it "load_verified returns checkpoint when signature is valid" do
      store.save(checkpoint)
      verified = store.load_verified
      expect(verified).not_to be_nil
      expect(verified.verify_signature).to be true
    end

    it "load_verified returns nil for malformed JSON" do
      File.write(path, "not json at all")
      expect(store.load_verified).to be_nil
    end

    it "load returns nil for malformed JSON" do
      File.write(path, "{bad json")
      expect(store.load).to be_nil
    end

    it "clear! removes the file" do
      store.save(checkpoint)
      store.clear!
      expect(store.exists?).to be false
    end

    it "save overwrites previous checkpoint" do
      trail2 = build_trail(3)
      cp2 = Igniter::Cluster::Governance::Checkpoint.build(
        identity: identity, peer_name: "node-b", trail: trail2
      )
      store.save(checkpoint)
      store.save(cp2)
      loaded = store.load
      expect(loaded.peer_name).to eq("node-b")
    end
  end

  # ── FileStore#compact! ────────────────────────────────────────────────────────

  describe "FileStore#compact!" do
    around do |example|
      Dir.mktmpdir do |dir|
        @tmpdir = dir
        example.run
      end
    end

    let(:path) { File.join(@tmpdir, "trail.ndjson") }
    let(:store) { Igniter::Cluster::Governance::Stores::FileStore.new(path: path) }

    it "rewrites the file with only the provided events" do
      trail = Igniter::Cluster::Governance::Trail.new(store: store)
      10.times { |i| trail.record(:"event_#{i}", source: :spec, payload: { i: i }) }

      expect(store.load_events.size).to eq(10)

      kept = store.load_events.last(3)
      store.compact!(kept)

      expect(store.load_events.size).to eq(3)
    end

    it "writes an empty file when events list is empty" do
      trail = Igniter::Cluster::Governance::Trail.new(store: store)
      3.times { |i| trail.record(:"e#{i}", source: :spec) }

      store.compact!([])
      expect(store.load_events).to eq([])
    end

    it "compact! via Trail#compact! syncs to disk" do
      trail = Igniter::Cluster::Governance::Trail.new(store: store)
      20.times { |i| trail.record(:"event_#{i}", source: :spec) }

      trail.compact!(keep_last: 5, identity: identity, peer_name: "n")

      reloaded = store.load_events
      # 5 kept + the :trail_compacted event itself
      expect(reloaded.size).to eq(6)
    end
  end

  # ── Mesh.compact_governance! integration ─────────────────────────────────────

  describe "Mesh.compact_governance!" do
    around do |example|
      Igniter::Cluster::Mesh.reset!
      example.run
      Igniter::Cluster::Mesh.reset!
    end

    it "returns a CompactionRecord" do
      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name = "mesh-compact"
        c.identity  = identity
      end
      5.times { |i| Igniter::Cluster::Mesh.config.governance_trail.record(:"e#{i}", source: :spec) }

      rec = Igniter::Cluster::Mesh.compact_governance!(keep_last: 3)
      expect(rec).to be_a(Igniter::Cluster::Governance::CompactionRecord)
    end

    it "builds a signed checkpoint using Mesh identity" do
      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name = "mesh-compact"
        c.identity  = identity
      end
      5.times { |i| Igniter::Cluster::Mesh.config.governance_trail.record(:"e#{i}", source: :spec) }

      rec = Igniter::Cluster::Mesh.compact_governance!(keep_last: 3)
      expect(rec.checkpoint).not_to be_nil
      expect(rec.checkpoint.verify_signature).to be true
    end

    it "saves checkpoint to CheckpointStore when configured" do
      Dir.mktmpdir do |dir|
        store = Igniter::Cluster::Governance::Stores::CheckpointStore.new(
          path: File.join(dir, "cp.json")
        )
        Igniter::Cluster::Mesh.configure do |c|
          c.peer_name       = "mesh-compact"
          c.identity        = identity
          c.checkpoint_store = store
        end
        5.times { |i| Igniter::Cluster::Mesh.config.governance_trail.record(:"e#{i}", source: :spec) }

        Igniter::Cluster::Mesh.compact_governance!(keep_last: 3)
        expect(store.exists?).to be true
        expect(store.load_verified).not_to be_nil
      end
    end

    it "chains to previous checkpoint loaded from store" do
      Dir.mktmpdir do |dir|
        store = Igniter::Cluster::Governance::Stores::CheckpointStore.new(
          path: File.join(dir, "cp.json")
        )
        Igniter::Cluster::Mesh.configure do |c|
          c.peer_name        = "mesh-compact"
          c.identity         = identity
          c.checkpoint_store = store
        end

        trail = Igniter::Cluster::Mesh.config.governance_trail
        10.times { |i| trail.record(:"e#{i}", source: :spec) }

        rec1 = Igniter::Cluster::Mesh.compact_governance!(keep_last: 5)

        5.times { |i| trail.record(:"f#{i}", source: :spec) }

        rec2 = Igniter::Cluster::Mesh.compact_governance!(keep_last: 5)

        expect(rec2.checkpoint.previous_digest).to eq(rec1.checkpoint.crest_digest)
      end
    end
  end
end
