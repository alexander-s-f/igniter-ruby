# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "wire_protocol"
require_relative "codecs"

module Igniter
  module Store
    # Partitioned, manifest-tracked WAL backend with pluggable per-store codecs.
    #
    # A single instance replaces FileBackend for a whole IgniterStore — facts
    # from every store are written into per-store, per-time-bucket segment
    # files under a shared root directory.
    #
    # Layout:
    #   {root_dir}/
    #     wal/
    #       store={name}/
    #         date={bucket}/
    #           segment-000001.wal
    #           segment-000001.wal.manifest.json   ← written atomically on seal
    #           segment-000002.wal
    #
    # Codec selection:
    #
    #   # All stores use the default codec (json_crc32):
    #   SegmentedFileBackend.new(root)
    #
    #   # All stores use compact_delta:
    #   SegmentedFileBackend.new(root, codec: :compact_delta)
    #
    #   # Per-store codec map (string or symbol keys):
    #   SegmentedFileBackend.new(root,
    #     codec: { technician_locations: :compact_delta,
    #              vendor_leads:         :compact_delta,
    #              crm_records:          :json_crc32 })
    #
    # compact_delta is recommended for high-frequency History stores (sensor
    # readings, GPS tracks) and gives ~16x size reduction over json_crc32.
    # It is NOT resumable after a crash — any live compact_delta segment is
    # sealed on the next startup and a fresh segment is opened.
    #
    # Public interface is identical to FileBackend: write_fact, replay, close.
    class SegmentedFileBackend
      include WireProtocol

      MANIFEST_SUFFIX    = ".manifest.json"
      PURGED_SUFFIX      = ".purged.json"
      QUARANTINE_SUFFIX  = ".quarantine.json"
      DEFAULT_MAX_BYTES  = 64 * 1024 * 1024  # 64 MB
      DEFAULT_CODEC      = :json_crc32
      SCHEMA_VERSION     = 1

      attr_reader :root_dir

      # +root_dir+    — root data directory shared by all stores.
      # +max_bytes+   — rotate segment when file reaches this size (default 64 MB).
      # +time_bucket+ — :day (default), :hour, or :none.
      # +codec+       — Symbol or Hash{store_name => Symbol}.  See class docs.
      # +retention+ — Hash{ store_name => { strategy:, duration: } }
      #   Strategies:
      #     :permanent      — never purge (default when no policy set)
      #     :rolling_window — purge sealed segments where max_timestamp < now - duration (Float seconds)
      #     :ephemeral      — keep only the single newest sealed segment per store
      # +flush+ — durability policy applied after every +write_fact+:
      #   :batch      — (default) flush only at BATCH_SIZE, close, or checkpoint.
      #                 compact_delta facts < BATCH_SIZE are lost on a crash.
      #   :on_write   — flush after every single fact (safest, smallest write window).
      #   { every_n: N } — flush after every N facts per store.
      #
      # json_crc32 writes every fact immediately regardless of this setting.
      def initialize(root_dir, max_bytes: DEFAULT_MAX_BYTES, time_bucket: :day,
                     codec: DEFAULT_CODEC, retention: {}, flush: :batch)
        @root_dir           = root_dir.to_s
        @max_bytes          = max_bytes
        @time_bucket        = time_bucket
        @codec_spec         = codec      # Symbol or Hash
        @flush_policy       = flush
        @segments           = {}         # store_name (String) → segment state Hash
        @retention_policies = {}
        @mutex              = Mutex.new

        FileUtils.mkdir_p(File.join(@root_dir, "wal"))
        retention.each { |store, policy| set_retention(store, **policy) }
        recover_orphaned_segments!
      end

      def write_fact(fact)
        store = fact.store.to_s
        @mutex.synchronize do
          seg = active_segment_for(store)
          seg[:codec].encode_fact(seg[:file], fact)
          seg[:count] += 1
          ts = fact.transaction_time.to_f
          seg[:min_ts] = seg[:min_ts] ? [seg[:min_ts], ts].min : ts
          seg[:max_ts] = seg[:max_ts] ? [seg[:max_ts], ts].max : ts
          apply_flush_policy(seg)
        end
      end

      # Returns all facts from matching segments sorted by timestamp.
      # +store+  — restrict to one store name (Symbol or String); nil = all stores.
      # +since+  — skip sealed segments with max_timestamp < since (Float unix sec).
      # +as_of+  — skip sealed segments with min_timestamp > as_of (Float unix sec).
      def replay(store: nil, since: nil, as_of: nil)
        segment_paths_for(store: store ? store.to_s : nil, since: since, as_of: as_of)
          .flat_map { |path| read_segment(path) }
          .sort_by(&:transaction_time)
      end

      # Seal every open segment and open a fresh one per store.
      def checkpoint!
        @mutex.synchronize do
          old = @segments.dup
          @segments.clear
          old.each do |store, seg|
            seal_segment!(seg)
            @segments[store] = open_new_segment(store)
          end
        end
      end

      def close
        @mutex.synchronize do
          @segments.values.each { |seg| seal_segment!(seg) }
          @segments.clear
        end
      end

      def segment_count
        all_segment_paths.size
      end

      def stored_store_names
        Dir[File.join(@root_dir, "wal", "store=*")]
          .select { |d| File.directory?(d) }
          .map    { |d| File.basename(d).sub("store=", "") }
      end

      # Register (or replace) the retention policy for a store.
      def set_retention(store, strategy:, duration: nil)
        @mutex.synchronize do
          @retention_policies[store.to_s] = { strategy: strategy.to_sym, duration: duration }
        end
      end

      # Delete eligible sealed segments for stores that have a policy.
      # Returns an Array of receipt hashes (one per deleted segment).
      # Live (unsealed) segments are never touched.
      # +store+ — restrict purge to one store; nil = all stores with a policy.
      def purge!(store: nil)
        @mutex.synchronize do
          targets = store ? [store.to_s] : @retention_policies.keys
          targets.flat_map { |s| purge_store!(s) }
        end
      end

      # List purge receipts written by previous purge! calls.
      # +store+  — restrict to one store; nil = all stores.
      # +since+  — only receipts where purged_at >= since (Float unix sec).
      # +until_+ — only receipts where purged_at <= until_ (Float unix sec).
      # +limit+  — return at most this many, ordered by purged_at ascending.
      def purge_receipts(store: nil, since: nil, until_: nil, limit: nil)
        glob = store ? "store=#{store}" : "store=*"
        receipts = Dir[File.join(@root_dir, "wal", glob, "**", "*#{PURGED_SUFFIX}")]
                     .map { |p| JSON.parse(File.read(p)) rescue nil }
                     .compact
                     .sort_by { |r| r["purged_at"] || 0 }
        receipts = receipts.select { |r| (r["purged_at"] || 0) >= since    } if since
        receipts = receipts.select { |r| (r["purged_at"] || 0) <= until_   } if until_
        receipts = receipts.first(limit)                                       if limit
        receipts
      end

      # List quarantine receipts for segments that could not be decoded.
      # +store+ — restrict to one store; nil = all stores.
      def quarantine_receipts(store: nil)
        glob = store ? "store=#{store}" : "store=*"
        Dir[File.join(@root_dir, "wal", glob, "**", "*#{QUARANTINE_SUFFIX}")]
          .map { |p| JSON.parse(File.read(p)) rescue nil }
          .compact
      end

      # Detailed per-segment manifest for one or all stores.
      # Includes a "segments" array with one entry per segment (sealed + live).
      # Safe to call while the backend is open.
      def segment_manifest(store: nil)
        @mutex.synchronize do
          build_storage_view(store: store ? store.to_s : nil, include_segments: true)
        end
      end

      # Compact aggregate stats for one or all stores.
      # No per-segment detail — suitable for health checks and protocol metadata.
      def storage_stats(store: nil)
        @mutex.synchronize do
          build_storage_view(store: store ? store.to_s : nil, include_segments: false)
        end
      end

      # Returns the current durability posture: configured policy plus a per-store
      # breakdown showing how many facts are buffered in memory vs. on disk.
      #
      # Buffered facts are at risk of loss on a process crash. A "flushed" store
      # has all accepted facts on disk; a "buffered" store has unflushed in-memory
      # facts that would be lost if the process were killed right now.
      def durability_snapshot
        @mutex.synchronize do
          stores_snap = @segments.to_h do |name, seg|
            buffered = seg[:codec].buffered_count
            [name, {
              "codec"          => seg[:codec_name].to_s,
              "buffered_count" => buffered,
              "facts_on_disk"  => seg[:count] - buffered,
              "durability"     => buffered > 0 ? "buffered" : "flushed"
            }]
          end
          { "policy" => flush_policy_name, "stores" => stores_snap }
        end
      end

      private

      # ── Retention ────────────────────────────────────────────────────────

      def purge_store!(store)
        policy = @retention_policies[store]
        return [] unless policy

        now    = Process.clock_gettime(Process::CLOCK_REALTIME)
        live   = @segments[store]&.dig(:path)
        sealed = sealed_segment_paths(store)

        to_delete = select_for_purge(sealed, policy, now)
        to_delete.reject! { |p| p == live }

        to_delete.map { |p| delete_segment_with_receipt!(p, policy, now) }.compact
      end

      def sealed_segment_paths(store)
        Dir[File.join(@root_dir, "wal", "store=#{store}", "**", "segment-*.wal")]
          .reject { |p| p.end_with?(MANIFEST_SUFFIX) || p.end_with?(PURGED_SUFFIX) }
          .select { |p| File.exist?(p + MANIFEST_SUFFIX) }
          .sort
      end

      def select_for_purge(paths, policy, now)
        case policy[:strategy]
        when :permanent
          []
        when :rolling_window
          duration = policy[:duration].to_f
          paths.select { |p|
            m      = JSON.parse(File.read(p + MANIFEST_SUFFIX)) rescue nil
            next false unless m
            max_ts = m["max_timestamp"]
            max_ts && max_ts < (now - duration)
          }
        when :ephemeral
          paths.empty? ? [] : paths[0..-2]
        else
          []
        end
      end

      def delete_segment_with_receipt!(path, policy, now)
        mpath = path + MANIFEST_SUFFIX
        manifest = File.exist?(mpath) ? (JSON.parse(File.read(mpath)) rescue {}) : {}

        receipt = manifest.merge(
          "purged_at"      => now,
          "purge_strategy" => policy[:strategy].to_s,
          "purge_duration" => policy[:duration],
          "segment_path"   => path,
          "reason"         => purge_reason(policy, manifest, now)
        )

        receipt_path = path + PURGED_SUFFIX
        File.write(receipt_path, JSON.generate(receipt))

        FileUtils.rm_f(path)
        FileUtils.rm_f(mpath)
        receipt
      end

      def purge_reason(policy, manifest, now)
        store_name = manifest["store"] || "unknown"
        seg_id     = manifest["segment_id"] || "unknown"
        case policy[:strategy].to_sym
        when :rolling_window
          age = now - (manifest["max_timestamp"] || now)
          "rolling_window: segment #{seg_id} (store=#{store_name}) max_timestamp #{age.round(1)}s older than retention window of #{policy[:duration]}s"
        when :ephemeral
          "ephemeral: segment #{seg_id} (store=#{store_name}) superseded by newer sealed segment"
        else
          "#{policy[:strategy]}: segment #{seg_id} (store=#{store_name}) purged by policy"
        end
      end

      # ── Flush policy ─────────────────────────────────────────────────────

      def apply_flush_policy(seg)
        case @flush_policy
        when :on_write
          seg[:codec].flush(seg[:file])
          seg[:file].flush
        when Hash
          n = @flush_policy[:every_n]
          if n
            seg[:facts_since_flush] = (seg[:facts_since_flush] || 0) + 1
            if seg[:facts_since_flush] >= n
              seg[:codec].flush(seg[:file])
              seg[:file].flush
              seg[:facts_since_flush] = 0
            end
          end
        end
        # :batch — no extra flush beyond what the codec already does at BATCH_SIZE
      end

      def flush_policy_name
        case @flush_policy
        when :batch    then "batch"
        when :on_write then "on_write"
        when Hash      then "every_n:#{@flush_policy[:every_n]}"
        else                @flush_policy.to_s
        end
      end

      # ── Codec resolution ─────────────────────────────────────────────────

      def codec_name_for(store)
        case @codec_spec
        when Symbol, String then @codec_spec.to_sym
        when Hash
          (@codec_spec[store.to_sym] || @codec_spec[store.to_s] || DEFAULT_CODEC).to_sym
        else DEFAULT_CODEC
        end
      end

      # ── Segment lifecycle ─────────────────────────────────────────────────

      def active_segment_for(store)
        @segments[store] ||= open_or_resume_segment(store)
        rotate_if_needed!(store)
        @segments[store]
      end

      def rotate_if_needed!(store)
        seg      = @segments[store]
        on_disk  = File.size?(seg[:path]) || 0
        if current_bucket != seg[:bucket] || on_disk >= @max_bytes
          seal_segment!(seg)
          @segments[store] = open_new_segment(store)
        end
      end

      # Resume a live (unsealed) json_crc32 segment if one exists in the
      # current bucket.  compact_delta segments are NOT resumable — any live
      # segment is sealed and a fresh one is started.
      def open_or_resume_segment(store)
        bucket = current_bucket
        dir    = store_bucket_dir(store, bucket)
        FileUtils.mkdir_p(dir)

        live = Dir[File.join(dir, "segment-*.wal")]
                 .reject { |p| p.end_with?(MANIFEST_SUFFIX) }
                 .reject { |p| File.exist?(p + MANIFEST_SUFFIX) }
                 .max_by { |p| segment_number_from_path(p) }

        cname = codec_name_for(store)

        if live && cname == :json_crc32
          resume_segment(live, store, bucket, cname)
        else
          seal_orphaned_live!(live, codec_name: cname) if live
          open_new_segment_in(store, bucket, cname)
        end
      end

      def resume_segment(path, store, bucket, codec_name)
        file = File.open(path, "ab")
        file.sync = true
        codec = Codecs.build(codec_name)
        { path: path, file: file, store: store, bucket: bucket,
          number: segment_number_from_path(path), codec_name: codec_name,
          codec: codec, count: count_frames(path), min_ts: nil, max_ts: nil }
      end

      def open_new_segment(store)
        open_new_segment_in(store, current_bucket, codec_name_for(store))
      end

      def open_new_segment_in(store, bucket, codec_name)
        dir      = store_bucket_dir(store, bucket)
        FileUtils.mkdir_p(dir)
        next_num = (segment_numbers_in(dir).max || 0) + 1
        path     = segment_path_for(store, bucket, next_num)
        file     = File.open(path, "ab")
        file.sync = true
        codec    = Codecs.build(codec_name)
        codec.start_segment(file, store: store)
        { path: path, file: file, store: store, bucket: bucket,
          number: next_num, codec_name: codec_name,
          codec: codec, count: 0, min_ts: nil, max_ts: nil }
      end

      # Seal a live segment that belongs to a previous session or a codec
      # that cannot be resumed (compact_delta).  No manifest metadata is
      # available so we only write a minimal one.
      def seal_orphaned_live!(path, codec_name: DEFAULT_CODEC)
        file = File.open(path, "ab")
        file.flush
        file.close
        store_name = path.split("store=").last.split("/").first
        bucket     = path.split("date=").last.split("/").first
        number     = segment_number_from_path(path)
        if File.size(path) == 0
          FileUtils.rm_f(path)
          return
        end
        write_manifest(path, codec: codec_name.to_s,
                       fact_count: count_frames_for_codec(path, codec_name),
                       byte_size:  File.size(path), min_ts: nil, max_ts: nil,
                       store: store_name, bucket: bucket, number: number)
      end

      def seal_segment!(seg)
        return unless seg
        seg[:codec].flush(seg[:file])
        seg[:file].flush
        seg[:file].close
        if seg[:count] == 0
          FileUtils.rm_f(seg[:path])
          return
        end
        write_manifest(seg[:path],
                       codec:      seg[:codec].name,
                       fact_count: seg[:count],
                       byte_size:  File.size(seg[:path]),
                       min_ts:     seg[:min_ts],
                       max_ts:     seg[:max_ts],
                       store:      seg[:store],
                       bucket:     seg[:bucket],
                       number:     seg[:number])
      end

      def write_manifest(path, codec:, fact_count:, byte_size:, min_ts:, max_ts:,
                         store:, bucket:, number:)
        manifest = {
          segment_id:    segment_id(store, bucket, number),
          store:         store,
          codec:         codec,
          fact_count:    fact_count,
          byte_size:     byte_size,
          min_timestamp: min_ts,
          max_timestamp: max_ts,
          sealed:        true,
          sealed_at:     Process.clock_gettime(Process::CLOCK_REALTIME)
        }
        tmp = path + MANIFEST_SUFFIX + ".tmp"
        File.write(tmp, JSON.generate(manifest))
        FileUtils.mv(tmp, path + MANIFEST_SUFFIX)
      end

      # ── Replay ────────────────────────────────────────────────────────────

      def segment_paths_for(store:, since:, as_of:)
        glob = store ? "store=#{store}" : "store=*"
        all  = Dir[File.join(@root_dir, "wal", glob, "date=*", "segment-*.wal")]
                 .reject { |p| p.end_with?(MANIFEST_SUFFIX) }
                 .sort
        return all unless since || as_of

        all.select { |path|
          mpath = path + MANIFEST_SUFFIX
          next true unless File.exist?(mpath)

          m      = JSON.parse(File.read(mpath))
          max_ts = m["max_timestamp"]
          min_ts = m["min_timestamp"]
          next false if since && max_ts && max_ts < since
          next false if as_of  && min_ts && min_ts > as_of
          true
        }
      end

      def read_segment(path)
        codec_name = manifest_codec_for(path)
        codec = Codecs.build(codec_name)
        facts = File.open(path, "rb") { |io| codec.decode(io) }
        if facts.empty? && segment_expects_facts?(path)
          write_quarantine_receipt(path, RuntimeError.new("segment not empty but decoded 0 facts"))
        end
        facts
      rescue StandardError => e
        write_quarantine_receipt(path, e)
        []
      end

      def manifest_codec_for(path)
        mpath = path + MANIFEST_SUFFIX
        return DEFAULT_CODEC unless File.exist?(mpath)
        (JSON.parse(File.read(mpath))["codec"] || DEFAULT_CODEC.to_s).to_sym
      rescue StandardError
        DEFAULT_CODEC
      end

      # ── Path helpers ──────────────────────────────────────────────────────

      def store_bucket_dir(store, bucket)
        File.join(@root_dir, "wal", "store=#{store}", "date=#{bucket}")
      end

      def segment_path_for(store, bucket, number)
        File.join(store_bucket_dir(store, bucket), "segment-#{number.to_s.rjust(6, "0")}.wal")
      end

      def segment_id(store, bucket, number)
        "#{store}/#{bucket}/#{number.to_s.rjust(6, "0")}"
      end

      def segment_number_from_path(path)
        File.basename(path, ".wal").split("-").last.to_i
      end

      def all_segment_paths
        Dir[File.join(@root_dir, "wal", "store=*", "date=*", "segment-*.wal")]
          .reject { |p| p.end_with?(MANIFEST_SUFFIX) }
      end

      def segment_numbers_in(dir)
        Dir[File.join(dir, "segment-*.wal")]
          .reject { |p| p.end_with?(MANIFEST_SUFFIX) }
          .map    { |p| segment_number_from_path(p) }
      end

      def current_bucket
        case @time_bucket
        when :hour then Time.now.utc.strftime("%Y-%m-%dT%H")
        when :none then "flat"
        else            Time.now.utc.strftime("%Y-%m-%d")
        end
      end

      def count_frames(path)
        return 0 unless File.exist?(path)
        n = 0
        File.open(path, "rb") { |f| n += 1 while read_frame(f) }
        n
      rescue StandardError
        0
      end

      # For compact_delta the first frame is a header, subsequent frames are batches.
      # Each batch carries a count prefix — sum those instead of counting raw frames.
      def count_frames_for_codec(path, codec_name)
        return count_frames(path) unless codec_name.to_sym == :compact_delta_zlib ||
                                         codec_name.to_sym == :compact_delta
        return 0 unless File.exist?(path)
        total = 0
        File.open(path, "rb") do |f|
          read_frame(f)  # skip header
          while (body = read_frame(f))
            total += body[0, 4].unpack1("N") rescue 0
          end
        end
        total
      rescue StandardError
        0
      end

      def write_quarantine_receipt(path, error)
        mpath = path + MANIFEST_SUFFIX
        manifest = File.exist?(mpath) ? (JSON.parse(File.read(mpath)) rescue {}) : {}
        receipt = manifest.merge(
          "quarantined_at" => Process.clock_gettime(Process::CLOCK_REALTIME),
          "error_class"    => error.class.to_s,
          "error_message"  => error.message.to_s[0, 500],
          "segment_path"   => path
        )
        File.write(path + QUARANTINE_SUFFIX, JSON.generate(receipt))
      rescue StandardError
        nil  # never raise from error-handler path
      end

      def segment_expects_facts?(path)
        mpath = path + MANIFEST_SUFFIX
        return false unless File.exist?(mpath)
        (JSON.parse(File.read(mpath))["fact_count"] || 0).to_i > 0
      rescue StandardError
        false
      end

      # On startup, seal any live segments that were left open by a previous crash.
      # Codec is detected by peeking at the first frame rather than relying on the
      # current codec config (the store may have been reconfigured between sessions).
      def recover_orphaned_segments!
        Dir[File.join(@root_dir, "wal", "store=*", "date=*")].each do |dir|
          orphans = Dir[File.join(dir, "segment-*.wal")]
                      .reject { |p| p.end_with?(MANIFEST_SUFFIX) || p.end_with?(PURGED_SUFFIX) || p.end_with?(QUARANTINE_SUFFIX) }
                      .reject { |p| File.exist?(p + MANIFEST_SUFFIX) }
          orphans.each { |p| seal_orphaned_live!(p, codec_name: detect_segment_codec(p)) }
        end
      end

      # Peek at the first frame of a segment file and determine its codec.
      def detect_segment_codec(path)
        File.open(path, "rb") do |f|
          body = read_frame(f)
          return DEFAULT_CODEC unless body&.length&.> 0
          parsed = MessagePack.unpack(body)
          return :compact_delta_zlib if parsed.is_a?(Hash) && parsed.key?("fields")
          DEFAULT_CODEC
        end
      rescue StandardError
        DEFAULT_CODEC
      end

      # ── Storage metadata ──────────────────────────────────────────────────

      def build_storage_view(store:, include_segments:)
        target_stores = store ? [store] : manifest_store_names
        now = Process.clock_gettime(Process::CLOCK_REALTIME)
        {
          "schema_version" => SCHEMA_VERSION,
          "generated_at"   => now,
          "stores"         => target_stores.sort.to_h { |s| [s, build_store_stats(s, include_segments: include_segments)] }
        }
      end

      def build_store_stats(store, include_segments:)
        sealed_manifests = Dir[File.join(@root_dir, "wal", "store=#{store}", "**", "segment-*.wal#{MANIFEST_SUFFIX}")]
                             .sort
                             .map { |p| JSON.parse(File.read(p)) rescue nil }
                             .compact

        live = @segments[store]

        total_facts = sealed_manifests.sum { |m| m["fact_count"].to_i }
        total_facts += live[:count] if live
        total_bytes = sealed_manifests.sum { |m| m["byte_size"].to_i }
        total_bytes += (File.size?(live[:path]) || 0) if live
        codecs = (sealed_manifests.map { |m| m["codec"] } +
                  (live ? [live[:codec_name].to_s] : [])).uniq.compact.sort

        min_ts = (sealed_manifests.map { |m| m["min_timestamp"] }.compact +
                  (live&.dig(:min_ts) ? [live[:min_ts]] : [])).min
        max_ts = (sealed_manifests.map { |m| m["max_timestamp"] }.compact +
                  (live&.dig(:max_ts) ? [live[:max_ts]] : [])).max

        purge_count      = Dir[File.join(@root_dir, "wal", "store=#{store}", "**", "*#{PURGED_SUFFIX}")].size
        quarantine_count = Dir[File.join(@root_dir, "wal", "store=#{store}", "**", "*#{QUARANTINE_SUFFIX}")].size

        stats = {
          "segment_count"            => sealed_manifests.size + (live ? 1 : 0),
          "sealed_count"             => sealed_manifests.size,
          "live_count"               => live ? 1 : 0,
          "codecs"                   => codecs,
          "byte_size"                => total_bytes,
          "fact_count"               => total_facts,
          "min_timestamp"            => min_ts,
          "max_timestamp"            => max_ts,
          "purge_receipt_count"      => purge_count,
          "quarantine_receipt_count" => quarantine_count
        }

        if include_segments
          segs = sealed_manifests.map { |m|
            m.slice("segment_id", "codec", "fact_count", "byte_size",
                    "min_timestamp", "max_timestamp", "sealed", "sealed_at")
          }
          if live
            segs << {
              "segment_id"    => segment_id(live[:store], live[:bucket], live[:number]),
              "codec"         => live[:codec_name].to_s,
              "fact_count"    => live[:count],
              "byte_size"     => File.size?(live[:path]) || 0,
              "min_timestamp" => live[:min_ts],
              "max_timestamp" => live[:max_ts],
              "sealed"        => false,
              "sealed_at"     => nil
            }
          end
          stats["segments"] = segs
        end

        stats
      end

      def manifest_store_names
        disk = stored_store_names
        live = @segments.keys
        (disk + live).uniq
      end
    end
  end
end
