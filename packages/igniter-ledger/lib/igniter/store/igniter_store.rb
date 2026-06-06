# frozen_string_literal: true

require "digest"
require "securerandom"
require "set"

module Igniter
  module Store
    # Thin wrapper returned from read paths when a schema coercion is registered.
    # Delegates identity fields to the underlying fact; exposes the coerced value.
    CoercedFact = Struct.new(:fact, :value) do
      def key              = fact.key
      def id               = fact.id
      def transaction_time = fact.transaction_time
      def valid_time       = fact.valid_time
      def schema_version   = fact.schema_version
      def causation        = fact.causation
      def value_hash       = fact.value_hash
      def store            = fact.store
      def producer         = fact.producer
      def derivation       = fact.derivation
      # Backward-compat aliases
      alias_method :timestamp, :transaction_time
      alias_method :term,      :valid_time
    end

    class IgniterStore
      attr_reader :schema_graph, :changefeed

      # Returns a Protocol::Interpreter wrapping this store.
      # External / non-Igniter clients use this surface to register descriptors,
      # write facts, and query via the open protocol vocabulary.
      def protocol
        @protocol ||= Protocol::Interpreter.new(self)
      end

      # Convenience shorthand: register a protocol descriptor packet.
      def register_descriptor(packet)
        protocol.register(packet)
      end

      def initialize(backend: nil, lru_cap: ReadCache::DEFAULT_LRU_CAP, changefeed: nil)
        @backend      = backend
        @lru_cap      = lru_cap
        @changefeed   = changefeed
        @log          = FactLog.new
        @cache        = ReadCache.new(lru_cap: lru_cap)
        @schema_graph = SchemaGraph.new
        # Materialized scope index: { [store, scope] => Set<key> }
        # Populated lazily on first query; maintained on every write thereafter.
        # Time-travel queries (as_of: non-nil) bypass the index.
        @scope_index  = {}
        @scope_mutex  = Mutex.new
        # Partition index: { [store, partition_key] => { partition_value => [fact, ...] } }
        # Populated lazily on first history_partition call; maintained on every append thereafter.
        # as_of/since filtering is applied at read time over the pre-grouped slice.
        @partition_index = {}
        @partition_mutex = Mutex.new
        # Schema coercion hooks: { store_name => callable(value, schema_version) }
        # Applied on every read path; raw facts remain immutable in the log and cache.
        @coercions = {}
        # Fact-id lookup index: { fact_id => Fact }
        # Maintained on write, append, replay, and rebuild_log!.
        # Reflects currently live facts only — dropped facts are removed after compaction.
        @fact_id_index = {}
      end

      def self.open(path, lru_cap: ReadCache::DEFAULT_LRU_CAP)
        backend = FileBackend.new(path)
        store = new(backend: backend, lru_cap: lru_cap)
        backend.replay.each { |fact| store.__send__(:replay, fact) }
        store
      end

      def register_projection(projection_path)
        @schema_graph.register_projection(projection_path)
        self
      end

      # Register a reactive derivation rule.
      # When any fact is written to +source_store+ (filtered by +source_filters+),
      # +rule+ is called with the current source facts and the result is written
      # to +target_store+ at +target_key+.  Returning nil from +rule+ skips the write.
      # Derivations do not re-trigger on derived writes (cycle-safe).
      # Declare a retention policy for +store+.
      # strategy: :permanent (default — never compact)
      #           :ephemeral — keep only the latest fact per key
      #           :rolling_window — keep latest per key + facts within duration seconds
      # Call compact or compact(store) to execute the policy.
      def set_retention(store, strategy:, duration: nil)
        @schema_graph.register_retention(
          store,
          RetentionPolicy.new(strategy: strategy, duration: duration)
        )
        self
      end

      # Run compaction for +store+ (or all stores with registered retention policies).
      # Returns an Array of result hashes: { store:, strategy:, dropped_count:,
      # kept_count:, receipt_id: }.  Permanent stores and stores with nothing to
      # drop return dropped_count: 0 and receipt_id: nil.
      def compact(store = nil)
        targets = store ? [store] : @schema_graph.retention_stores
        targets.filter_map do |s|
          policy = @schema_graph.retention_for(store: s)
          next unless policy && policy.strategy != :permanent
          compact_store(s, policy)
        end
      end

      # Facts written by compaction runs for +store+ (or all receipts when nil).
      # Receipts live in the :__compaction_receipts meta-store.
      def compaction_receipts(store: nil)
        all = @log.facts_for(store: :__compaction_receipts)
        store ? all.select { |f| f.value[:compacted_store] == store } : all
      end

      # Normalized compaction activity across all executors.
      #
      # Merges entries from:
      #   :__compaction_receipts   — retention compaction (store.compact)
      #   :__fact_prune_receipts   — exact fact-id prune (store.prune_fact_ids)
      #   backend.purge_receipts   — segment purge (SegmentedFileBackend.purge!)
      #
      # Each entry: { kind:, executor:, store:, status:, reason:, fact_count:,
      #               receipt_id:, occurred_at: }
      #
      # Boundary-specific receipts are not included here; use
      # AvailabilityBoundaryLedger#compaction_activity for the full picture.
      def compaction_activity(store: nil)
        entries = []

        compaction_receipts(store: store).each do |f|
          v = f.value
          entries << {
            kind:        :retention_compaction,
            executor:    :store_compact,
            store:       v[:compacted_store],
            status:      :ok,
            reason:      v[:strategy],
            fact_count:  v[:compacted_count].to_i,
            receipt_id:  f.id,
            occurred_at: v[:compacted_at].to_f
          }
        end

        @log.facts_for(store: :__fact_prune_receipts).each do |f|
          v = f.value
          entries << {
            kind:        :exact_prune,
            executor:    :fact_prune,
            store:       nil,
            status:      :ok,
            reason:      v[:reason],
            fact_count:  v[:pruned_count].to_i,
            receipt_id:  f.id,
            occurred_at: v[:pruned_at].to_f
          }
        end

        if @backend.respond_to?(:purge_receipts)
          @backend.purge_receipts(store: store).each do |r|
            entries << {
              kind:        :segment_purge,
              executor:    :segmented_backend,
              store:       r["store"]&.to_sym,
              status:      :ok,
              reason:      r["purge_strategy"],
              fact_count:  r["fact_count"].to_i,
              receipt_id:  r["segment_path"],
              occurred_at: r["purged_at"].to_f
            }
          end
        end

        entries.sort_by { |e| e[:occurred_at] }
      end

      # Removes exact facts by id from the live FactLog and all derived indexes.
      #
      # Requires a backend that supports +replace_with_snapshot!+ (i.e. FileBackend
      # in the Ruby-path proof).  Returns { status: :unsupported } for backends
      # that do not support durable fact removal (e.g. SegmentedFileBackend).
      # In-memory stores (backend: nil) support the operation without durability.
      #
      # Order of operations:
      #   1. Write a prune receipt (compact refs, no full payloads) — survives the prune.
      #   2. Rebuild log without the pruned facts.
      #   3. Call backend.replace_with_snapshot! so dropped facts cannot resurface on reopen.
      #
      # Missing fact ids are reported in the result but are not fatal.
      #
      # Returns:
      #   { status: :ok, receipt_id:, pruned_count:, missing_count:,
      #     pruned_fact_refs:, missing_ids: }
      #   { status: :unsupported, reason: :backend_does_not_support_exact_prune, backend: }
      def prune_fact_ids(fact_ids:, reason:, metadata: {}, receipt_store: :__fact_prune_receipts)
        if @backend && !@backend.respond_to?(:replace_with_snapshot!)
          return {
            status:  :unsupported,
            reason:  :backend_does_not_support_exact_prune,
            backend: @backend.class.name
          }
        end

        ids_set = Set.new(fact_ids.map(&:to_s))

        pruned_refs = []
        missing_ids = []
        ids_set.each do |id|
          fact = @fact_id_index[id]
          if fact
            pruned_refs << {
              id:               fact.id,
              store:            fact.store,
              key:              fact.key,
              transaction_time: fact.transaction_time,
              valid_time:       fact.valid_time,
              value_hash:       fact.value_hash
            }
          else
            missing_ids << id
          end
        end

        now     = Process.clock_gettime(Process::CLOCK_REALTIME)
        receipt = write(
          store: receipt_store,
          key:   SecureRandom.hex(8),
          value: {
            type:             :fact_prune_receipt,
            reason:           reason,
            requested_count:  ids_set.size,
            pruned_count:     pruned_refs.size,
            missing_count:    missing_ids.size,
            pruned_fact_refs: pruned_refs,
            missing_ids:      missing_ids,
            metadata:         metadata,
            pruned_at:        now
          }
        )

        surviving = @log.all_facts.reject { |f| ids_set.include?(f.id.to_s) }
        rebuild_log!(surviving)

        @backend.replace_with_snapshot!(@log.all_facts) if @backend

        {
          status:           :ok,
          receipt_id:       receipt.id,
          pruned_count:     pruned_refs.size,
          missing_count:    missing_ids.size,
          pruned_fact_refs: pruned_refs,
          missing_ids:      missing_ids
        }
      end

      # Declare a named cross-store relation backed by a materialized scatter index.
      #
      # When any fact is written to +source+, the value of +partition+ in that
      # fact is used as a key into the index store :"__rel_<name>".  The index
      # entry accumulates the unique source keys that share that partition value.
      #
      # resolve(name, from: value) reads the index and returns the current values
      # of all matching source facts (latest per key).
      #
      # This is a 1-N relation: one partition_key value → many source keys.
      # The index is append-only (G-Set): facts are never removed from the index.
      def register_relation(name, source:, partition:, target:)
        rule = RelationRule.new(name: name, source: source, partition: partition, target: target)
        @schema_graph.register_relation(rule)

        index_store = :"__rel_#{name}"
        register_scatter(
          source_store: source,
          partition_by: partition,
          target_store: index_store,
          rule: lambda { |partition_key, existing, new_fact|
            keys = existing ? existing[:keys].dup : []
            keys << new_fact.key unless keys.include?(new_fact.key)
            { keys: keys, count: keys.size, partition_key: partition_key }
          }
        )
        self
      end

      # Resolve a named relation for a given partition value.
      # Returns an Array of values of all source facts whose partition field
      # equals +from+.  Returns [] when nothing is indexed yet.
      #
      # as_of: Float timestamp — when given, reads the index state AND each
      # source value at that point in time (consistent point-in-time snapshot).
      def resolve(relation_name, from:, as_of: nil)
        rule = @schema_graph.relation_for(name: relation_name)
        raise ArgumentError, "No relation registered: #{relation_name.inspect}" unless rule

        index_entry = read(store: :"__rel_#{relation_name}", key: from.to_s, as_of: as_of)
        return [] unless index_entry

        index_entry[:keys].filter_map { |key| read(store: rule.source, key: key, as_of: as_of) }
      end

      # Register a scatter derivation rule.
      # When a fact is written to +source_store+, the value of +partition_by+ in
      # that fact's value is extracted as the target key.  +rule+ is called as:
      #   rule.(partition_key, existing_value, new_fact) → Hash | nil
      # Returning nil skips the write.  Scatter writes do not re-trigger scatter
      # (cycle-safe via a separate thread-local guard).
      def register_scatter(source_store:, partition_by:, target_store:, rule:)
        @schema_graph.register_scatter(
          ScatterRule.new(
            source_store: source_store,
            partition_by: partition_by,
            target_store: target_store,
            rule:         rule
          )
        )
        self
      end

      def register_derivation(source_store:, source_filters: {}, target_store:, target_key:, rule:)
        @schema_graph.register_derivation(
          DerivationRule.new(
            source_store:   source_store,
            source_filters: source_filters,
            target_store:   target_store,
            target_key:     target_key,
            rule:           rule
          )
        )
        self
      end

      def register_path(path)
        @schema_graph.register(path)
        path.consumers.to_a.each do |consumer|
          if path.scope
            @cache.register_scope_consumer(path.store, path.scope, consumer)
          else
            @cache.register_consumer(path.store, consumer)
          end
        end
        self
      end

      # Register a schema migration hook for +store_name+.
      # The block receives (value, schema_version) and must return the migrated value.
      # Applied on every read (point reads, scope queries, history); raw facts are
      # never mutated — coercion is a read-path transform only.
      def register_coercion(store_name, &block)
        @coercions[store_name] = block
        self
      end

      def write(store:, key:, value:, schema_version: 1, causation: nil, valid_time: nil, term: nil,
                producer: nil, derivation: nil)
        previous = @log.latest_for(store: store, key: key)
        fact = Fact.build(
          store:          store,
          key:            key,
          value:          value,
          causation:      causation || previous&.id,
          schema_version: schema_version,
          valid_time:     valid_time,
          term:           term,
          producer:       producer,
          derivation:     derivation
        )
        @log.append(fact)
        @fact_id_index[fact.id] = fact
        @backend&.write_fact(fact)
        scope_changes = update_scope_indices(store, key, value)
        @cache.invalidate(store: store, key: key, scope_changes: scope_changes)
        # Emit source fact before derived/scatter writes so subscribers see
        # cause before effects (source-first emission order).
        @changefeed&.emit(fact)
        run_derivations(store: store, source_fact: fact)
        run_scatters(store: store, source_fact: fact)
        fact
      end

      def append(history:, event:, schema_version: 1, valid_time: nil, term: nil, partition_key: nil,
                 producer: nil, derivation: nil)
        fact = Fact.build(
          store:          history,
          key:            SecureRandom.uuid,
          value:          event,
          schema_version: schema_version,
          valid_time:     valid_time,
          term:           term,
          producer:       producer,
          derivation:     derivation
        )
        @log.append(fact)
        @fact_id_index[fact.id] = fact
        @backend&.write_fact(fact)
        if partition_key && (pv = event[partition_key])
          idx_key = [history, partition_key]
          @partition_mutex.synchronize do
            if @partition_index.key?(idx_key)
              (@partition_index[idx_key][pv] ||= []) << fact
            end
          end
        end
        @changefeed&.emit(fact)
        fact
      end

      def read(store:, key:, as_of: nil, ttl: nil)
        cached = @cache.get(store: store, key: key, as_of: as_of, ttl: ttl)
        return coerce_value(store, cached) if cached

        fact = @log.latest_for(store: store, key: key, as_of: as_of)
        return nil unless fact

        @cache.put(store: store, key: key, fact: fact, as_of: as_of)
        coerce_value(store, fact)
      end

      def time_travel(store:, key:, at:)
        read(store: store, key: key, as_of: at)
      end

      def query(store:, scope:, as_of: nil, ttl: nil)
        path = @schema_graph.path_for(store: store, scope: scope)
        raise ArgumentError, "No registered path for store=#{store.inspect} scope=#{scope.inspect}" unless path

        effective_ttl = ttl || path.cache_ttl
        cached = @cache.get_scope(store: store, scope: scope, as_of: as_of, ttl: effective_ttl)
        return apply_coercions(store, cached) if cached

        filters = path.filters || {}
        facts = if as_of
          # Time-travel: bypass scope index — the index reflects current state only.
          @log.query_scope(store: store, filters: filters, as_of: as_of)
        else
          scope_key = [store, scope]
          idx = @scope_mutex.synchronize { @scope_index[scope_key] }
          if idx
            # Index is warm: O(matched_keys) read instead of O(all_keys) scan.
            idx.filter_map { |k| @log.latest_for(store: store, key: k) }
          else
            # First query for this scope: full scan + build index.
            all_facts = @log.query_scope(store: store, filters: filters, as_of: nil)
            @scope_mutex.synchronize do
              @scope_index[scope_key] ||= Set.new(all_facts.map(&:key))
            end
            all_facts
          end
        end

        @cache.put_scope(store: store, scope: scope, facts: facts, as_of: as_of)
        apply_coercions(store, facts)
      end

      def history(store:, key: nil, since: nil, as_of: nil)
        apply_coercions(store, @log.facts_for(store: store, key: key, since: since, as_of: as_of))
      end

      # Partition-filtered history query backed by a materialized index.
      # First call for a (store, partition_key) pair performs a full scan and
      # builds the index; subsequent calls are O(partition slice).
      # as_of/since filtering is applied over the cached slice at read time.
      def history_partition(store:, partition_key:, partition_value:, since: nil, as_of: nil)
        idx_key = [store, partition_key]
        @partition_mutex.synchronize do
          unless @partition_index.key?(idx_key)
            all_facts = @log.facts_for(store: store)
            groups    = Hash.new { |h, k| h[k] = [] }
            all_facts.each do |f|
              pv = f.value[partition_key]
              groups[pv] << f if pv
            end
            @partition_index[idx_key] = groups
          end

          slice = (@partition_index[idx_key][partition_value] || []).dup
          slice = slice.select { |f| f.transaction_time >= since } if since
          slice = slice.select { |f| f.transaction_time <= as_of } if as_of
          apply_coercions(store, slice)
        end
      end

      def causation_chain(store:, key:)
        history(store: store, key: key).map do |fact|
          {
            id:         fact.id,
            value_hash: fact.value_hash[0, 12],
            causation:  fact.causation,
            transaction_time: fact.transaction_time
          }
        end
      end

      # Returns a causal proof for the given store/key: the full fact chain in
      # chronological order, any registered derivation rules triggered by this
      # store, and a Merkle proof hash over the chain.
      #
      # proof_hash: SHA256 of "id:value_hash:causation" entries joined by "|".
      # Stable for the same chain; changes when any fact is added.
      # nil when the chain is empty (key unknown).
      #
      # derived_by: derivation rules registered for this store — what downstream
      # stores are affected by writes here.
      def lineage(store:, key:)
        chain = @log.facts_for(store: store, key: key).map do |fact|
          {
            id:               fact.id,
            store:            fact.store,
            key:              fact.key,
            causation:        fact.causation,
            value_hash:       fact.value_hash,
            transaction_time: fact.transaction_time,
            valid_time:       fact.valid_time,
            schema_version:   fact.schema_version
          }
        end

        derived_by = @schema_graph.derivations_for_store(store: store).map do |rule|
          {
            target_store:   rule.target_store,
            target_key:     rule.target_key.respond_to?(:call) ? :callable : rule.target_key,
            source_filters: rule.source_filters
          }
        end

        {
          subject:    { store: store, key: key },
          chain:      chain,
          depth:      chain.size,
          derived_by: derived_by,
          proof_hash: chain.empty? ? nil : lineage_proof_hash(chain)
        }
      end

      # Write a snapshot of the current fact log to the backend's snapshot file.
      # After a checkpoint, startup replay only replays facts written since the
      # snapshot — reducing startup cost from O(total_facts) to O(delta_facts).
      #
      # No-op when the backend or log does not support snapshot (e.g. in-memory
      # store or NATIVE FactLog without all_facts).  Returns self.
      def checkpoint
        if @backend.respond_to?(:write_snapshot) && @log.respond_to?(:all_facts)
          @backend.write_snapshot(@log.all_facts)
        end
        self
      end

      def fact_count
        @log.size
      end

      # Returns the exact Fact object for +fact_id+ if it is live in the store, nil otherwise.
      # Safe to call with nil or blank id — returns nil without raising.
      # Does not apply coercion; returns the raw Fact as written.
      def fact_by_id(fact_id)
        return nil if fact_id.nil? || fact_id.to_s.empty?
        @fact_id_index[fact_id]
      end

      # Returns compact metadata for +fact_id+ without exposing the full value payload.
      # Returns nil when the fact is not live.
      def fact_ref(fact_id)
        fact = fact_by_id(fact_id)
        return nil unless fact
        {
          id:               fact.id,
          store:            fact.store,
          key:              fact.key,
          transaction_time: fact.transaction_time,
          valid_time:       fact.valid_time,
          value_hash:       fact.value_hash
        }
      end

      # Return all facts from the log, optionally bounded by time range.
      # Used by the open protocol sync hub profile and replay operations.
      # Returns [] when the native FactLog lacks all_facts support.
      def fact_log_all(since: nil, as_of: nil)
        return [] unless @log.respond_to?(:all_facts)
        facts = @log.all_facts
        facts = facts.select { |f| f.transaction_time >= since } if since
        facts = facts.select { |f| f.transaction_time <= as_of  } if as_of
        facts
      end

      def close
        @backend&.close
      end

      # Returns storage metadata from the backend when it supports it.
      # Delegates to SegmentedFileBackend#storage_stats or returns nil for
      # backends that do not expose storage metadata (in-memory, FileBackend).
      def storage_stats(store: nil)
        return nil unless @backend.respond_to?(:storage_stats)
        @backend.storage_stats(store: store)
      end

      def segment_manifest(store: nil)
        return nil unless @backend.respond_to?(:segment_manifest)
        @backend.segment_manifest(store: store)
      end

      protected

      def replay(fact)
        @log.replay(fact)
        @fact_id_index[fact.id] = fact
      end

      private

      # Updates the materialized scope index for all scopes registered on +store+.
      # Returns a Hash of { scope_name => :changed | :unchanged | :unknown } so that
      # ReadCache can suppress consumer notifications for scopes whose membership
      # did not change.
      #
      # :unknown means the index was not yet initialised (no query has run for that
      # scope). ReadCache treats :unknown conservatively — it still notifies.
      def update_scope_indices(store, key, new_value)
        changes = {}
        # Multiple paths may share the same [store, scope] key (e.g. when on_scope
        # adds a consumer path alongside the register path).  Process each scope
        # exactly once — the shared Set must not be evaluated twice per write.
        seen_scopes = Set.new
        @schema_graph.paths_for(store).each do |path|
          next unless path.scope
          next unless seen_scopes.add?(path.scope)

          scope_key = [store, path.scope]
          filters   = path.filters || {}
          now_in    = matches_filters?(new_value, filters)

          @scope_mutex.synchronize do
            idx = @scope_index[scope_key]
            if idx.nil?
              changes[path.scope] = :unknown
            else
              was_in = idx.include?(key)
              if now_in && !was_in
                idx.add(key)
                changes[path.scope] = :changed
              elsif !now_in && was_in
                idx.delete(key)
                changes[path.scope] = :changed
              else
                changes[path.scope] = :unchanged
              end
            end
          end
        end
        changes
      end

      # --- Compaction internals ---

      def compact_store(store, policy)
        now         = Process.clock_gettime(Process::CLOCK_REALTIME)
        store_facts = @log.facts_for(store: store)
        keep, drop  = partition_compaction(store_facts, policy, now: now)

        return { store: store, strategy: policy.strategy, dropped_count: 0, kept_count: keep.size, receipt_id: nil, durable: false } if drop.empty?

        # Belt 7b — write receipt to meta-store before rebuilding log
        receipt = write_compaction_receipt(store, drop, policy, now)

        # Rebuild log: all other stores + compaction receipts + kept facts for this store
        surviving = @log.all_facts.reject { |f| f.store == store }
        surviving << receipt unless surviving.any? { |f| f.id == receipt.id }
        new_facts = (surviving + keep).sort_by(&:transaction_time)
        rebuild_log!(new_facts)

        # Use the pruning-safe barrier when the backend supports it so that
        # compacted facts cannot resurrect on reopen.  Fall back to the
        # non-destructive checkpoint when only write_snapshot is available
        # (in-memory durability only), and skip entirely for in-memory stores.
        durable = if @backend.respond_to?(:replace_with_snapshot!)
          @backend.replace_with_snapshot!(@log.all_facts)
          true
        elsif @backend.respond_to?(:write_snapshot) && @log.respond_to?(:all_facts)
          @backend.write_snapshot(@log.all_facts)
          false
        else
          false
        end

        { store: store, strategy: policy.strategy, dropped_count: drop.size, kept_count: keep.size, receipt_id: receipt.id, durable: durable }
      end

      # Returns [keep_facts, drop_facts]. Latest fact per key is always kept.
      def partition_compaction(facts, policy, now:)
        latest_ids = facts.group_by(&:key).transform_values { |fs| fs.max_by(&:transaction_time).id }
        current    = Set.new(latest_ids.values)

        case policy.strategy
        when :ephemeral
          keep = facts.select { |f| current.include?(f.id) }
          drop = facts.reject { |f| current.include?(f.id) }
        when :rolling_window
          cutoff = now - policy.duration.to_f
          keep   = facts.select { |f| current.include?(f.id) || f.transaction_time >= cutoff }
          drop   = facts.reject { |f| current.include?(f.id) || f.transaction_time >= cutoff }
        else
          keep = facts
          drop = []
        end

        [keep, drop]
      end

      # Write a compaction receipt fact to the :__compaction_receipts meta-store.
      def write_compaction_receipt(store, dropped_facts, policy, now)
        oldest = dropped_facts.min_by(&:transaction_time)
        newest = dropped_facts.max_by(&:transaction_time)
        write(
          store: :__compaction_receipts,
          key:   "#{store}_#{SecureRandom.hex(4)}",
          value: {
            type:            :compaction_receipt,
            compacted_store: store,
            strategy:        policy.strategy,
            compacted_count: dropped_facts.size,
            oldest_dropped:  oldest&.id,
            newest_dropped:  newest&.id,
            oldest_ts:       oldest&.transaction_time,
            newest_ts:       newest&.transaction_time,
            compacted_at:    now
          }
        )
      end

      # Replace the in-memory FactLog with a rebuilt one from +new_facts+.
      # Clears all derived indices (scope index, partition index, read cache) —
      # they will be rebuilt lazily on next access.
      def rebuild_log!(new_facts)
        new_log = FactLog.new
        new_facts.each { |f| new_log.replay(f) }

        # Native FactLog tracks seen stores only via the Ruby append patch;
        # replay bypasses it so we backfill manually.
        if defined?(Igniter::Store::NATIVE) && Igniter::Store::NATIVE
          seen = new_facts.map(&:store).uniq
          new_log.instance_variable_set(:@_seen_stores, seen)
        end

        @log = new_log
        @fact_id_index = new_facts.each_with_object({}) { |f, h| h[f.id] = f }
        @scope_mutex.synchronize     { @scope_index.clear }
        @partition_mutex.synchronize { @partition_index.clear }
        @cache = ReadCache.new(lru_cap: @lru_cap)
      end

      def lineage_proof_hash(chain)
        input = chain.map { |e| "#{e[:id]}:#{e[:value_hash]}:#{e[:causation]}" }.join("|")
        Digest::SHA256.hexdigest(input)
      end

      # Runs all derivation rules registered for +store+ unless we are already inside
      # a derivation (cycle guard via thread-local flag).
      def run_derivations(store:, source_fact:)
        return if Thread.current[:igniter_deriving]

        rules = @schema_graph.derivations_for_store(store: store)
        return if rules.empty?

        Thread.current[:igniter_deriving] = true
        begin
          rules.each do |rule|
            source_facts  = @log.query_scope(store: rule.source_store, filters: rule.source_filters)
            derived_value = rule.rule.call(source_facts)
            next unless derived_value

            tk = rule.target_key.respond_to?(:call) ? rule.target_key.call(source_facts) : rule.target_key.to_s
            write(store: rule.target_store, key: tk, value: derived_value)
          end
        ensure
          Thread.current[:igniter_deriving] = false
        end
      end

      # Runs all scatter rules registered for +store+ unless we are already inside
      # a scatter derivation (separate cycle guard from gather derivations).
      # Extracts partition_by field from the triggering fact's value, reads the
      # current index entry, calls rule.(partition_key, existing, new_fact), and
      # writes the result when non-nil.
      def run_scatters(store:, source_fact:)
        return if Thread.current[:igniter_scattering]

        rules = @schema_graph.scatters_for_store(store: store)
        return if rules.empty?

        Thread.current[:igniter_scattering] = true
        begin
          rules.each do |rule|
            partition_value = source_fact.value[rule.partition_by]
            next unless partition_value

            target_key     = partition_value.to_s
            existing_value = read(store: rule.target_store, key: target_key)
            derived_value  = rule.rule.call(partition_value, existing_value, source_fact)
            next unless derived_value

            write(store: rule.target_store, key: target_key, value: derived_value)
          end
        ensure
          Thread.current[:igniter_scattering] = false
        end
      end

      def matches_filters?(value, filters)
        return false unless value.is_a?(Hash)
        filters.all? { |k, v| value[k] == v }
      end

      # Returns the coerced value for a single fact point-read.
      def coerce_value(store, fact)
        coercion = @coercions[store]
        return fact.value unless coercion

        coercion.call(fact.value, fact.schema_version)
      end

      # Wraps each fact in a CoercedFact when a coercion is registered for +store+.
      # Returns the original array unchanged when no coercion is registered (preserves
      # object identity for TTL cache equality checks).
      def apply_coercions(store, facts)
        coercion = @coercions[store]
        return facts unless coercion

        facts.map do |f|
          original = f.value
          coerced  = coercion.call(original, f.schema_version)
          coerced.equal?(original) ? f : CoercedFact.new(f, coerced)
        end
      end
    end
  end
end
