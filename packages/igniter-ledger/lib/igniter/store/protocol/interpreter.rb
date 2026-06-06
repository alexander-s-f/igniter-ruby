# frozen_string_literal: true

require "digest"
require "time"

module Igniter
  module Store
    module Protocol
      class Interpreter
        HANDLERS = {
          store:        Handlers::StoreHandler,
          history:      Handlers::HistoryHandler,
          access_path:  Handlers::AccessPathHandler,
          relation:     Handlers::RelationHandler,
          projection:   Handlers::ProjectionHandler,
          derivation:   Handlers::DerivationHandler,
          command:      Handlers::CommandHandler,
          effect:       Handlers::EffectHandler,
          subscription: Handlers::SubscriptionHandler,
        }.freeze

        # Default thresholds for storage-level alerts in observability_snapshot.
        # Override per-interpreter via alert_thresholds: at construction time.
        DEFAULT_STORAGE_ALERT_THRESHOLDS = {
          quarantine_receipt_count: 10,
          storage_byte_size:        1_073_741_824   # 1 GiB
        }.freeze

        def initialize(store, alert_thresholds: {})
          @store            = store
          @registry         = {}  # content fingerprint → Receipt (dedup)
          @alert_thresholds = DEFAULT_STORAGE_ALERT_THRESHOLDS.merge(alert_thresholds)
        end

        # Generic descriptor registration — dispatches by kind:.
        # Returns a Receipt with status :accepted, :rejected, or :deduplicated.
        def register(descriptor)
          descriptor = descriptor.transform_keys(&:to_sym)
          kind = descriptor[:kind]&.to_sym

          return Receipt.rejection("Missing required field: kind") unless kind

          handler_class = HANDLERS[kind]
          return Receipt.rejection("Unknown descriptor kind: #{kind.inspect}", kind: kind) unless handler_class

          fp = fingerprint(descriptor)
          return Receipt.deduplicated(kind: kind, name: descriptor[:name]&.to_sym) if @registry.key?(fp)

          receipt = handler_class.new(@store).call(descriptor)
          @registry[fp] = receipt if receipt.accepted?
          receipt
        end

        # Named registration helpers — vocabulary aliases for register.
        def register_store(descriptor)        = register(descriptor)
        def register_history(descriptor)      = register(descriptor)
        def register_access_path(descriptor)  = register(descriptor)
        def register_relation(descriptor)     = register(descriptor)
        def register_projection(descriptor)   = register(descriptor)
        def register_derivation(descriptor)   = register(descriptor)
        def register_command(descriptor)      = register(descriptor)
        def register_effect(descriptor)       = register(descriptor)
        def register_subscription(descriptor) = register(descriptor)

        # Write a fact. Returns a write Receipt carrying fact_id and value_hash.
        def write(store:, key:, value:, causation: nil, valid_time: nil, term: nil,
                  producer: nil, derivation: nil)
          fact = @store.write(
            store:      store.to_sym,
            key:        key,
            value:      value,
            causation:  causation,
            valid_time: valid_time,
            term:       term,
            producer:   producer,
            derivation: derivation
          )
          Receipt.write_accepted(store: store.to_sym, key: key, fact: fact)
        end

        # Append an event to a history. Returns an append Receipt carrying the
        # generated fact key, fact_id, and value_hash.
        def append(history:, event:, key: nil, partition_key: nil, schema_version: 1,
                   valid_time: nil, term: nil, producer: nil, derivation: nil)
          fact = @store.append(
            history:        history.to_sym,
            event:          event,
            schema_version: schema_version,
            valid_time:     valid_time,
            term:           term,
            partition_key:  partition_key&.to_sym,
            producer:       producer,
            derivation:     derivation
          )
          Receipt.append_accepted(history: history.to_sym, fact: fact, requested_key: key)
        end

        # Accept a full fact packet hash (kind: :fact) and write it to the store.
        # Designed for wire replay, server ingestion, and protocol-native clients.
        # Note: at: is recorded in the packet but cannot override the engine timestamp —
        # the engine assigns monotonic timestamps on write.
        def write_fact(packet)
          packet = packet.transform_keys(&:to_sym)
          kind = packet[:kind]&.to_sym
          return Receipt.rejection("write_fact: expected kind: :fact, got #{kind.inspect}", kind: :fact) unless kind == :fact

          store = packet[:store]
          key   = packet[:key]
          value = packet[:value]
          return Receipt.rejection("write_fact: missing store:",  kind: :fact) unless store
          return Receipt.rejection("write_fact: missing key:",    kind: :fact) unless key
          return Receipt.rejection("write_fact: missing value:",  kind: :fact) unless value

          fact = @store.write(
            store:      store.to_sym,
            key:        key.to_s,
            value:      value,
            causation:  packet[:causation],
            valid_time: packet[:valid_time],
            term:       packet[:term],
            producer:   packet[:producer],
            derivation: packet[:derivation]
          )
          Receipt.write_accepted(store: store.to_sym, key: key, fact: fact)
        end

        # Read the current value for a key (or nil).
        def read(store:, key:, as_of: nil)
          @store.read(store: store.to_sym, key: key, as_of: as_of)
        end

        # Query facts matching all where: conditions.
        # Performs a latest-per-key scan; access paths provide introspection metadata
        # but index-accelerated query planning is a future engine concern.
        def query(store:, where: {}, order: nil, limit: nil, as_of: nil)
          store_sym = store.to_sym
          facts = @store.history(store: store_sym, as_of: as_of)

          # Reduce to latest fact per key.
          latest = {}
          facts.each do |f|
            existing = latest[f.key]
            latest[f.key] = f if existing.nil? || f.transaction_time > existing.transaction_time
          end

          rows = latest.values

          where.each do |field, val|
            sym = field.to_sym
            rows = rows.select { |fact| fact.value[sym] == val }
          end

          rows = rows.sort_by { |fact| fact.value[order.to_sym] } if order
          rows = rows.first(limit) if limit
          rows.map { |fact| { key: fact.key, value: fact.value } }
        end

        # Resolve a named relation (delegates to IgniterStore#resolve).
        def resolve(relation_name, from:, as_of: nil)
          @store.resolve(relation_name, from: from, as_of: as_of)
        end

        # Read-only provenance: compact causation chain for one store/key.
        def causation_chain(store:, key:)
          @store.causation_chain(store: store.to_sym, key: key)
        end

        # Read-only provenance: causal proof and downstream derivation metadata.
        def lineage(store:, key:)
          @store.lineage(store: store.to_sym, key: key)
        end

        # Read-only provenance: compact fact reference, without fact value.
        def fact_ref(fact_id)
          @store.fact_ref(fact_id)
        end

        # Resolve a named relation with source keys preserved for client-side
        # typed record reconstruction. The value-only #resolve API remains
        # stable for existing protocol callers.
        def resolve_items(relation_name, from:, as_of: nil)
          rule = @store.schema_graph.relation_for(name: relation_name)
          raise ArgumentError, "No relation registered: #{relation_name.inspect}" unless rule

          index_entry = @store.read(store: :"__rel_#{relation_name}", key: from.to_s, as_of: as_of)
          return [] unless index_entry

          index_entry[:keys].filter_map do |key|
            value = @store.read(store: rule.source, key: key, as_of: as_of)
            { key: key, value: value } if value
          end
        end

        # OP2: unified protocol metadata snapshot.
        # Combines raw descriptor registry (store/history/subscription),
        # engine routing metadata (access paths), and all derived graph artifacts
        # (relations, projections, derivations, scatters, retention) into one
        # canonical introspection response.
        # Used by Companion, StoreServer, visual tools, and compliance test kits.
        def metadata_snapshot
          g = @store.schema_graph
          ds = g.descriptor_snapshot
          snap = {
            schema_version: 1,
            stores:        ds[:stores],
            histories:     ds[:histories],
            access_paths:  g.metadata_snapshot,
            relations:     g.relation_snapshot,
            projections:   g.projection_snapshot,
            commands:      g.command_snapshot,
            effects:       g.effect_snapshot,
            derivations:   g.derivation_snapshot,
            scatters:      g.scatter_snapshot,
            subscriptions: ds[:subscriptions],
            retention:     g.retention_snapshot
          }
          stats = @store.storage_stats
          snap[:storage] = stats if stats
          snap
        end

        # Physical storage stats from the backend (SegmentedFileBackend).
        # Returns nil when the backend does not support it.
        def storage_stats(store: nil)
          @store.storage_stats(store: store)
        end

        # Detailed per-segment manifest from the backend.
        # Returns nil when the backend does not support it.
        def segment_manifest(store: nil)
          @store.segment_manifest(store: store)
        end

        # Raw descriptor-only snapshot (store/history/subscription).
        # Use metadata_snapshot for the full picture; this is a lower-level accessor.
        def descriptor_snapshot
          @store.schema_graph.descriptor_snapshot
        end

        # OP4: generates a SyncProfile for a cold hub or incremental update.
        #
        # Full sync (cursor: nil):     all facts + full descriptor snapshot
        # Incremental (cursor: given): facts since cursor[:value] timestamp + snapshot
        # stores: Array<Symbol>        optional store filter (nil = all stores)
        #
        # The returned SyncProfile#next_cursor should be persisted by the hub and
        # sent back as cursor: on the next call to receive only new facts.
        def sync_hub_profile(as_of: nil, cursor: nil, stores: nil)
          from = cursor&.dig(:value)

          raw_facts = @store.fact_log_all(since: from, as_of: as_of)

          if stores
            allowed = Array(stores).map(&:to_sym).to_set
            raw_facts = raw_facts.select { |f| allowed.include?(f.store) }
          end

          fact_packets = raw_facts.map { |f| serialize_fact(f) }

          SyncProfile.new(
            schema_version:           1,
            kind:                     :sync_hub_profile,
            generated_at:             Process.clock_gettime(Process::CLOCK_REALTIME),
            cursor:                   cursor,
            descriptors:              metadata_snapshot,
            facts:                    fact_packets,
            retention:                @store.schema_graph.retention_snapshot,
            compaction_receipts:      compaction_receipt_summaries,
            compaction_activity:      compaction_activity,
            subscription_checkpoints: {}
          )
        end

        # Normalized compaction lifecycle activity.
        #
        # Returns a response envelope with schema_version, generated_at, filters,
        # activity (normalized entries), and count.
        #
        # Filtering:
        #   store:  delegate to IgniterStore#compaction_activity(store:)
        #   kind:   filter entries by :kind
        #   since:  keep entries where occurred_at >= since
        #   limit:  cap result count after all other filters
        def compaction_activity(store: nil, kind: nil, since: nil, limit: nil)
          store_sym = store&.to_sym
          entries = @store.compaction_activity(store: store_sym)

          entries = entries.select { |e| e[:kind].to_s == kind.to_s } if kind
          entries = entries.select { |e| e[:occurred_at] >= since.to_f } if since
          entries = entries.first(limit.to_i) if limit

          {
            schema_version: 1,
            generated_at:   Time.now.iso8601(3),
            filters: {
              store: store&.to_s,
              kind:  kind&.to_s,
              since: since&.to_f,
              limit: limit&.to_i
            },
            activity: entries,
            count:    entries.size
          }
        end

        # OP4: return all (or range-filtered) facts as serialized fact packets.
        # Suitable for WAL replay to a cold hub or test double.
        #
        # Filter forms:
        #   { store: :name }
        #   { store: :name, key: "event-key" }
        #   { store: :name, partition_key: :tracker_id, partition_value: "sleep" }
        def replay(from: nil, to: nil, filter: nil)
          if filter
            filter = filter.transform_keys(&:to_sym)
            store_sym = filter[:store]&.to_sym

            if store_sym && filter.key?(:key)
              return @store.history(
                store: store_sym,
                key:   filter[:key],
                since: from,
                as_of: to
              ).map { |f| serialize_fact(f) }
            end

            if store_sym && filter[:partition_key] && filter.key?(:partition_value)
              return @store.history_partition(
                store:           store_sym,
                partition_key:   filter[:partition_key].to_sym,
                partition_value: filter[:partition_value],
                since:           from,
                as_of:           to
              ).map { |f| serialize_fact(f) }
            end
          end

          raw_facts = @store.fact_log_all(since: from, as_of: to)
          raw_facts = raw_facts.select { |f| f.store == filter[:store]&.to_sym } if filter && filter[:store]
          raw_facts.map { |f| serialize_fact(f) }
        end

        # OP3: returns the WireEnvelope router for this interpreter.
        # Accepts process-boundary envelope hashes and returns response envelopes.
        def wire
          @wire ||= WireEnvelope.new(self)
        end

        # OP3: convenience shorthand — dispatch one wire envelope hash.
        def dispatch(envelope)
          wire.dispatch(envelope)
        end

        # ── Observability ─────────────────────────────────────────────────────

        # Returns the canonical storage-level observability snapshot.
        #
        # Canonical shape (same top-level keys at every layer; server-only fields
        # are nil at the protocol level):
        #   schema_version, generated_at, status, uptime_ms (nil),
        #   metrics (nil), alerts, storage, server (nil)
        #
        # storage-level alerts (quarantine_receipt_count, storage_byte_size) are
        # checked against +alert_thresholds+ configured at construction time.
        def observability_snapshot
          storage = @store.storage_stats rescue nil
          alerts  = check_storage_alerts(storage)
          {
            schema_version: 1,
            generated_at:   Time.now.iso8601(3),
            status:         :ready,
            uptime_ms:      nil,
            metrics:        nil,
            alerts:         alerts,
            storage:        storage,
            server:         nil
          }
        end

        private

        def check_storage_alerts(storage)
          return [] unless storage
          alerts = []
          stores = storage["stores"] || {}

          qc = stores.values.sum { |s| s["quarantine_receipt_count"].to_i }
          t  = @alert_thresholds[:quarantine_receipt_count]
          if t && qc > t
            alerts << {
              type:          :quarantine_receipt_count,
              threshold:     t,
              current_value: qc,
              message:       "quarantine_receipt_count exceeded threshold: #{qc} > #{t}"
            }
          end

          bs = stores.values.sum { |s| s["byte_size"].to_i }
          t  = @alert_thresholds[:storage_byte_size]
          if t && bs > t
            alerts << {
              type:          :storage_byte_size,
              threshold:     t,
              current_value: bs,
              message:       "storage_byte_size exceeded threshold: #{bs} > #{t}"
            }
          end

          alerts
        end

        def fingerprint(descriptor)
          Digest::SHA256.hexdigest(descriptor.to_a.sort_by { |k, _| k.to_s }.inspect)
        end

        def serialize_fact(fact)
          {
            schema_version: 1,
            kind:       :fact,
            id:         fact.id,
            store:      fact.store,
            key:        fact.key,
            value:      fact.value,
            value_hash: fact.value_hash,
            causation:  fact.causation,
            transaction_time: fact.transaction_time,
            valid_time:       fact.valid_time,
            producer:         fact.producer,
            derivation:       fact.derivation
          }
        end

        def compaction_receipt_summaries
          @store.compaction_receipts.map do |f|
            {
              id:              f.id,
              compacted_store: f.value[:compacted_store],
              strategy:        f.value[:strategy],
              compacted_count: f.value[:compacted_count],
              compacted_at:    f.value[:compacted_at]
            }
          end
        end
      end
    end
  end
end
