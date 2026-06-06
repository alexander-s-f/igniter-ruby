# frozen_string_literal: true

require "json"
require "zlib"
require "set"
require "fileutils"
require_relative "wire_protocol"

module Igniter
  module Store
    unless defined?(NATIVE) && NATIVE
      # Pure-Ruby FileBackend — skipped when the Rust native extension is loaded.
      #
      # WAL format (v2): length-prefixed frames with CRC32 integrity check.
      #
      # Each frame:
      #   [4 bytes BE uint32: body_len][body_len bytes: JSON][4 bytes BE uint32: CRC32(body)]
      #
      # Snapshot format (path + ".snap"):
      #   [header frame: JSON { type: "snapshot_header", fact_count: N, written_at: T }]
      #   [fact frame 1] ... [fact frame N]
      #
      # On open, if a snapshot file exists: snapshot facts are loaded first, WAL
      # facts whose IDs are already in the snapshot are skipped. Combined result
      # is sorted by timestamp. Startup cost is O(snapshot_size + delta_wal_size)
      # instead of O(total_wal_size).
      class FileBackend
        include WireProtocol

        SNAPSHOT_SUFFIX = ".snap"

        def initialize(path)
          @path = path.to_s
          @file = File.open(@path, "ab")
          @file.sync = true
        end

        def write_fact(fact)
          body  = JSON.generate(fact.to_h)
          @file.write(encode_frame(body))
        end

        # Combines snapshot (if present) + WAL delta into a chronologically
        # ordered list of facts.  Facts in the snapshot are deduplicated against
        # the WAL by ID so a checkpoint never causes double-replay.
        def replay
          snapshot_facts, seen_ids = load_snapshot
          wal_facts = read_wal_frames.reject { |f| seen_ids.include?(f.id) }
          (snapshot_facts + wal_facts).sort_by(&:transaction_time)
        end

        # Atomically writes all +facts+ to a snapshot file (<wal_path>.snap).
        # Uses a tmp file + rename so a partial write never corrupts an existing
        # snapshot.  The WAL file is untouched; the snapshot is a parallel read
        # artefact only.
        def write_snapshot(facts)
          tmp = "#{snapshot_path}.tmp"
          File.open(tmp, "wb") do |f|
            header = JSON.generate({
              type:       "snapshot_header",
              fact_count: facts.size,
              written_at: Process.clock_gettime(Process::CLOCK_REALTIME)
            })
            f.write(encode_frame(header))
            facts.each { |fact| f.write(encode_frame(JSON.generate(fact.to_h))) }
          end
          FileUtils.mv(tmp, snapshot_path)
        end

        # Pruning-safe barrier: atomically replace the snapshot with +facts+ AND
        # truncate the WAL so that dropped facts cannot resurface on reopen.
        #
        # Normal checkpoint (#write_snapshot) is non-destructive — it leaves the
        # WAL intact, which means any fact not present in the snapshot will still
        # be loaded from the WAL on next open.  For physical purge that is wrong:
        # the dropped fact ids would not be in the new snapshot, so the WAL would
        # replay them back into existence.
        #
        # This method:
        #   1. Writes the new snapshot atomically (tmp → rename).
        #   2. Closes the current WAL file handle.
        #   3. Truncates the WAL to 0 bytes (new open in write mode).
        #   4. Reopens for future appends.
        #
        # After a successful call, close/reopen will load only the snapshot facts.
        def replace_with_snapshot!(facts)
          write_snapshot(facts)
          @file.close
          File.open(@path, "wb") {}   # truncate WAL
          @file = File.open(@path, "ab")
          @file.sync = true
        end

        def snapshot_path
          @path + SNAPSHOT_SUFFIX
        end

        def close
          @file.close
        end

        private

        # Parses a raw JSON body into a frozen Fact.  Returns nil on parse error.
        def decode_fact(body)
          payload = JSON.parse(body, symbolize_names: true)
          Fact.from_h(payload)
        rescue JSON::ParserError
          nil
        end

        # --- WAL reading ---

        def read_wal_frames
          return [] unless File.exist?(@path)
          facts = []
          File.open(@path, "rb") do |f|
            loop do
              body = read_frame(f)
              break unless body
              fact = decode_fact(body)
              facts << fact if fact
            end
          end
          facts
        end

        # --- Snapshot reading ---

        # Returns [Array<Fact>, Set<id>] from the snapshot file, or [[], Set[]]
        # if no snapshot exists or the snapshot is corrupt.
        def load_snapshot
          return [[], Set.new] unless File.exist?(snapshot_path)

          facts = []
          File.open(snapshot_path, "rb") do |f|
            header_body = read_frame(f)
            return [[], Set.new] unless header_body

            header = JSON.parse(header_body, symbolize_names: true)
            return [[], Set.new] unless header[:type] == "snapshot_header"

            loop do
              body = read_frame(f)
              break unless body
              fact = decode_fact(body)
              facts << fact if fact
            end
          end

          [facts, Set.new(facts.map(&:id))]
        rescue StandardError
          [[], Set.new]
        end
      end
    end

    if defined?(NATIVE) && NATIVE
      # Patch native FileBackend to add snapshot support.
      # The native class exposes write_fact, replay (WAL-only), and close.
      # We add: write_snapshot, snapshot_path, SNAPSHOT_SUFFIX, and a
      # snapshot-aware replay that merges snapshot facts with the WAL delta.
      #
      # Deduplication uses the original fact id embedded in the snapshot JSON
      # (not the id on the reconstructed Fact object, which is regenerated by
      # Fact.build in native mode).

      module NativeFileBackendSnapshotSupport
        include WireProtocol

        SNAPSHOT_SUFFIX = ".snap"

        def snapshot_path
          @_ruby_path + SNAPSHOT_SUFFIX
        end

        # Pruning-safe barrier for native-backed stores.
        # Writes the snapshot atomically, then truncates the WAL file so that
        # dropped facts cannot be replayed on reopen.
        # The native write handle is still open; after truncation, the next
        # native write will restart from offset 0 (append mode semantics).
        def replace_with_snapshot!(facts)
          write_snapshot(facts)
          File.open(@_ruby_path, "wb") {}   # truncate WAL
        end

        def write_snapshot(facts)
          tmp = "#{snapshot_path}.tmp"
          File.open(tmp, "wb") do |f|
            header = JSON.generate({
              type:       "snapshot_header",
              fact_count: facts.size,
              written_at: Process.clock_gettime(Process::CLOCK_REALTIME)
            })
            f.write(encode_frame(header))
            facts.each { |fact| f.write(encode_frame(JSON.generate(fact.to_h))) }
          end
          FileUtils.mv(tmp, snapshot_path)
        end

        # Merges snapshot facts (if any) with WAL facts not already in the snapshot.
        # Deduplication is by original id read directly from the JSON frame, because
        # Fact.from_h in native mode regenerates ids via Fact.build.
        def replay
          snapshot_facts, seen_ids = load_native_snapshot
          wal_facts = _native_replay_wal
          delta = wal_facts.reject { |f| seen_ids.include?(f.id) }
          snapshot_facts + delta
        end

        private

        def load_native_snapshot
          return [[], Set.new] unless File.exist?(snapshot_path)

          facts    = []
          seen_ids = Set.new
          File.open(snapshot_path, "rb") do |f|
            header_body = read_frame(f)
            return [[], Set.new] unless header_body
            header = JSON.parse(header_body, symbolize_names: true)
            return [[], Set.new] unless header[:type] == "snapshot_header"

            loop do
              body = read_frame(f)
              break unless body
              h = JSON.parse(body, symbolize_names: true)
              seen_ids.add(h[:id]) if h[:id]
              fact = Fact.from_h(h)
              facts << fact if fact
            end
          end
          [facts, seen_ids]
        rescue StandardError
          [[], Set.new]
        end
      end

      class FileBackend
        include NativeFileBackendSnapshotSupport

        SNAPSHOT_SUFFIX = NativeFileBackendSnapshotSupport::SNAPSHOT_SUFFIX

        # The native extension defines `replay` (WAL-only) as a class-level method,
        # which shadows the module's snapshot-aware `replay`.  Save the WAL-only
        # version under an alias, then override `replay` in the class body so the
        # snapshot-aware path is used on store open.
        alias_method :_native_replay_wal, :replay

        def replay
          snapshot_facts, seen_ids = load_native_snapshot
          wal_facts = _native_replay_wal
          delta = wal_facts.reject { |f| seen_ids.include?(f.id) }
          snapshot_facts + delta
        end

        class << self
          alias_method :_native_new, :new

          def new(path)
            obj = _native_new(path)
            obj.instance_variable_set(:@_ruby_path, path.to_s)
            obj
          end
        end
      end
    end
  end
end
