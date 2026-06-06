# frozen_string_literal: true

require_relative "../../spec_helper"
require "tmpdir"
require "zlib"

RSpec.describe Igniter::Store::FileBackend do
  def tmp_path
    File.join(Dir.mktmpdir("igniter-store-spec"), "store.wal")
  end

  it "replays facts written across two sessions (WAL durability)" do
    path = tmp_path

    first = Igniter::Store.open(path)
    first.write(store: :tasks, key: "t1", value: { title: "Package", done: false })
    first.write(store: :tasks, key: "t1", value: { title: "Package", done: true })
    first.close

    replayed = Igniter::Store.open(path)

    expect(replayed.read(store: :tasks, key: "t1")).to include(done: true)
    expect(replayed.fact_count).to eq(2)
  end

  it "preserves causation chain across WAL replay" do
    path = tmp_path

    s1 = Igniter::Store.open(path)
    f1 = s1.write(store: :items, key: "k1", value: { v: 1 })
    f2 = s1.write(store: :items, key: "k1", value: { v: 2 })
    s1.close

    s2 = Igniter::Store.open(path)
    chain = s2.causation_chain(store: :items, key: "k1")

    expect(chain.length).to eq(2)
    expect(chain[0][:id]).to eq(f1.id)
    expect(chain[1][:causation]).to eq(f1.id)
  end

  it "stops replay at a truncated frame without raising and returns committed facts" do
    path = tmp_path

    s = Igniter::Store.open(path)
    s.write(store: :items, key: "k1", value: { v: 1 })
    s.write(store: :items, key: "k1", value: { v: 2 })
    s.close

    # Simulate a mid-write process kill: truncate the last 6 bytes
    File.open(path, "ab") { }   # no-op open to confirm file exists
    raw = File.binread(path)
    File.binwrite(path, raw[0...-6])

    replayed = Igniter::Store.open(path)
    # At least the first fact survived; the truncated second frame is ignored
    expect(replayed.fact_count).to be >= 1
    expect { replayed.read(store: :items, key: "k1") }.not_to raise_error
  end

  it "detects a CRC mismatch and stops replay at the corrupt frame" do
    path = tmp_path

    s = Igniter::Store.open(path)
    s.write(store: :items, key: "k1", value: { v: 1 })
    s.write(store: :items, key: "k1", value: { v: 2 })
    s.close

    # Flip a byte in the second frame's CRC (last 4 bytes of the file)
    raw = File.binread(path).bytes
    raw[-1] ^= 0xFF
    File.binwrite(path, raw.pack("C*"))

    replayed = Igniter::Store.open(path)
    # First frame (good CRC) replayed; second frame (bad CRC) stops replay
    expect(replayed.fact_count).to eq(1)
  end

  it "replays an empty WAL without error" do
    path = tmp_path
    FileUtils.touch(path)

    store = Igniter::Store.open(path)
    expect(store.fact_count).to eq(0)
  end

  describe "snapshot checkpoint" do
    it "checkpoint + reopen returns all facts (pre-snapshot and post-snapshot)" do
      path = tmp_path

      s1 = Igniter::Store.open(path)
      s1.write(store: :tasks, key: "t1", value: { v: 1 })
      s1.write(store: :tasks, key: "t2", value: { v: 2 })
      s1.checkpoint
      s1.write(store: :tasks, key: "t3", value: { v: 3 })
      s1.close

      s2 = Igniter::Store.open(path)
      expect(s2.fact_count).to eq(3)
      expect(s2.read(store: :tasks, key: "t1")).to include(v: 1)
      expect(s2.read(store: :tasks, key: "t2")).to include(v: 2)
      expect(s2.read(store: :tasks, key: "t3")).to include(v: 3)
    end

    it "creates a snapshot file alongside the WAL" do
      path = tmp_path

      s = Igniter::Store.open(path)
      s.write(store: :tasks, key: "t1", value: { v: 1 })
      s.checkpoint
      s.close

      expect(File.exist?(path + Igniter::Store::FileBackend::SNAPSHOT_SUFFIX)).to be true
    end

    it "reopening without WAL delta returns only snapshot facts" do
      path = tmp_path

      s1 = Igniter::Store.open(path)
      s1.write(store: :tasks, key: "t1", value: { v: 1 })
      s1.checkpoint
      s1.close

      # WAL still exists but all its facts are covered by the snapshot
      s2 = Igniter::Store.open(path)
      expect(s2.fact_count).to eq(1)
      expect(s2.read(store: :tasks, key: "t1")).to include(v: 1)
    end

    it "snapshot write is atomic: a corrupt tmp file does not affect the existing snapshot" do
      path = tmp_path

      s1 = Igniter::Store.open(path)
      s1.write(store: :tasks, key: "t1", value: { v: 1 })
      s1.checkpoint  # good snapshot
      s1.close

      # Simulate a crash during second checkpoint: corrupt the tmp file
      snap_tmp = path + Igniter::Store::FileBackend::SNAPSHOT_SUFFIX + ".tmp"
      File.write(snap_tmp, "CORRUPT")
      # The good snapshot must still be intact (tmp was never renamed)
      s2 = Igniter::Store.open(path)
      expect(s2.fact_count).to eq(1)
    end

    it "gracefully falls back to full WAL replay when snapshot is corrupt" do
      path = tmp_path

      s1 = Igniter::Store.open(path)
      s1.write(store: :tasks, key: "t1", value: { v: 1 })
      s1.checkpoint
      s1.close

      # Corrupt the snapshot file
      File.write(path + Igniter::Store::FileBackend::SNAPSHOT_SUFFIX, "GARBAGE")

      s2 = Igniter::Store.open(path)
      expect(s2.fact_count).to eq(1)  # recovered from WAL
      expect(s2.read(store: :tasks, key: "t1")).to include(v: 1)
    end

    it "preserves causation chain across checkpoint boundary" do
      path = tmp_path

      s1 = Igniter::Store.open(path)
      f1 = s1.write(store: :items, key: "k1", value: { v: 1 })
      s1.checkpoint
      f2 = s1.write(store: :items, key: "k1", value: { v: 2 })
      s1.close

      s2 = Igniter::Store.open(path)
      chain = s2.causation_chain(store: :items, key: "k1")
      expect(chain.length).to eq(2)
      expect(chain[1][:causation]).to eq(f1.id)
      expect(chain[1][:id]).to eq(f2.id)
    end
  end
end
