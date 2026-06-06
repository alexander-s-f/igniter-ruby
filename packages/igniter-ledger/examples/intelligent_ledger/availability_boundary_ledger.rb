# frozen_string_literal: true

require "securerandom"
require "digest"
require "time"
require_relative "availability_ledger"
require_relative "ledger_boundary"

module Igniter
  module Store
    module IntelligentLedger
      # Extends AvailabilityLedger with LedgerBoundary lifecycle management.
      #
      # Tracks boundaries in-memory (keyed by boundary_key) and persists
      # closure/settlement/compaction receipts to the store.
      #
      # Additional store layout:
      #   :ledger_boundaries                    — key: boundary_key
      #   :ledger_boundary_receipts             — key: boundary_key
      #   :ledger_boundary_summaries            — key: boundary_key  (settlement output)
      #   :ledger_boundary_metrics              — key: boundary_key  (settlement output)
      #   :ledger_settlement_receipts           — key: boundary_key  (settlement output)
      #   :ledger_cleanup_receipts              — key: boundary_key  (logical compaction receipt)
      #   :ledger_fact_redirects                — key: original_fact_id (written at compaction)
      #   :ledger_relation_edge_targets         — key: to_fact_id    (access path; canonical is :ledger_relation_edges)
      #   :ledger_cleanup_execution_receipts    — key: plan_hash     (idempotent execution record)
      #   :ledger_physical_purge_receipts       — key: plan_hash     (physical purge audit record)
      #   :late_fact_receipts                   — key: "late/<boundary_key>/<token>"
      #
      # Proof-known raw stores scanned by resolve_ref(:raw):
      RAW_PROOF_STORES = %i[availability_templates availability_overrides order_events].freeze

      class AvailabilityBoundaryLedger
        PRODUCER = {
          "system"  => "availability_boundary_ledger",
          "version" => LedgerBoundary::RULE_VERSION
        }.freeze

        def initialize(store:)
          @store      = store
          @ledger     = AvailabilityLedger.new(store: store)
          @boundaries = {}
        end

        # Delegate base fact writes to the underlying ledger.
        def write_template(...)    = @ledger.write_template(...)
        def write_override(...)    = @ledger.write_override(...)
        def write_order_event(...) = @ledger.write_order_event(...)

        # Opens a new boundary for a technician day (status: :open).
        def open_boundary(company_id:, technician_id:, date:)
          subject  = build_subject(company_id, technician_id, date)
          boundary = LedgerBoundary.new(subject: subject)
          @boundaries[boundary.boundary_key] = boundary
          boundary
        end

        # Returns the in-memory boundary for a given key, or nil.
        def find_boundary(boundary_key)
          @boundaries[boundary_key]
        end

        # Closes the boundary: derives snapshot, persists boundary records + receipts,
        # transitions boundary to :closed.
        #
        # Returns:
        #   { boundary:, snapshot_fact:, receipt_fact:, boundary_fact:, closure_receipt_fact: }
        def close_boundary(company_id:, technician_id:, date:, horizon_days: 1)
          boundary = find_or_open_boundary(company_id: company_id, technician_id: technician_id, date: date)

          result        = @ledger.compute_snapshot(
            technician_id: technician_id,
            horizon_start: coerce_date(date),
            horizon_days:  horizon_days
          )
          snapshot_fact = result[:snapshot_fact]
          receipt_fact  = result[:receipt_fact]
          source_ids    = snapshot_fact.value[:derived_from_fact_ids]  || []
          source_refs   = snapshot_fact.value[:derived_from_fact_refs] || []

          boundary.close!(
            output_fact:      snapshot_fact,
            receipt_fact:     receipt_fact,
            source_fact_ids:  source_ids,
            source_fact_refs: source_refs
          )

          boundary_fact = @store.write(
            store:    :ledger_boundaries,
            key:      boundary.boundary_key,
            value:    boundary_record_value(boundary),
            producer: PRODUCER
          )

          closure_receipt = @store.write(
            store:    :ledger_boundary_receipts,
            key:      boundary.boundary_key,
            value:    {
              "boundary_key"     => boundary.boundary_key,
              "output_fact_id"   => boundary.output_fact_id,
              "receipt_fact_id"  => boundary.receipt_fact_id,
              "result_hash"      => boundary.result_hash,
              "source_fact_ids"  => boundary.source_fact_ids,
              "source_fact_refs" => boundary.source_fact_refs,
              "detail_status"    => boundary.detail_status.to_s,
              "closed_at"        => boundary.closed_at.iso8601(3)
            },
            producer: PRODUCER
          )

          { boundary: boundary, snapshot_fact: snapshot_fact, receipt_fact: receipt_fact,
            boundary_fact: boundary_fact, closure_receipt_fact: closure_receipt }
        end

        # Settle a closed boundary: runs pre-compaction transforms (summary, metrics),
        # persists settlement receipt, transitions settlement_status to :settled.
        #
        # Settlement transforms:
        #   "availability_summary" — compact summary of the snapshot output
        #   "availability_metrics" — derived capacity metrics
        #
        # Returns:
        #   { boundary:, summary_fact:, metrics_fact:, settlement_receipt: }
        def settle_boundary(boundary_key)
          boundary = @boundaries[boundary_key]
          raise ArgumentError, "boundary not found: #{boundary_key}"         unless boundary
          raise ArgumentError, "boundary must be closed before settlement"   unless boundary.status == :closed
          raise ArgumentError, "boundary already settled"                    if boundary.settled?

          output       = boundary.output_value
          slots        = output[:available_slots] || []
          blocked      = output[:blocked_intervals] || []
          avail_secs   = output[:available_seconds].to_f
          blocked_secs = blocked.sum { |b| b[:end].to_f - b[:start].to_f }

          # Transform 1: availability summary
          summary_fact = @store.write(
            store:    :ledger_boundary_summaries,
            key:      boundary_key,
            value:    {
              "boundary_key"           => boundary_key,
              "summary_type"           => "availability",
              "available_seconds"      => avail_secs.to_i,
              "available_slot_count"   => slots.size,
              "blocked_interval_count" => blocked.size,
              "source_fact_count"      => boundary.source_fact_ids.size,
              "result_hash"            => boundary.result_hash
            },
            producer: PRODUCER
          )

          # Transform 2: capacity metrics (capacity_percent uses full 24h day as denominator)
          metrics_fact = @store.write(
            store:    :ledger_boundary_metrics,
            key:      boundary_key,
            value:    {
              "boundary_key"     => boundary_key,
              "capacity_percent" => (avail_secs / (24 * 3600.0) * 100).round(2),
              "available_hours"  => (avail_secs / 3600.0).round(4),
              "blocked_hours"    => (blocked_secs / 3600.0).round(4)
            },
            producer: PRODUCER
          )

          # Per-transform receipts (embedded in settlement receipt)
          transforms = [
            {
              "transform_name"     => "availability_summary",
              "transform_version"  => "1.0",
              "input_boundary_key" => boundary_key,
              "input_result_hash"  => boundary.result_hash,
              "output_fact_id"     => summary_fact.id,
              "status"             => "ok"
            },
            {
              "transform_name"     => "availability_metrics",
              "transform_version"  => "1.0",
              "input_boundary_key" => boundary_key,
              "input_result_hash"  => boundary.result_hash,
              "output_fact_id"     => metrics_fact.id,
              "status"             => "ok"
            }
          ]

          settlement_receipt = @store.write(
            store:    :ledger_settlement_receipts,
            key:      boundary_key,
            value:    {
              "boundary_key"      => boundary_key,
              "settlement_status" => "settled",
              "transform_names"   => transforms.map { |t| t["transform_name"] },
              "output_fact_ids"   => {
                "availability_summary" => summary_fact.id,
                "availability_metrics" => metrics_fact.id
              },
              "result_hash"       => boundary.result_hash,
              "transforms"        => transforms,
              "settled_at"        => Time.now.iso8601(3)
            },
            producer: PRODUCER
          )

          boundary.settle!(settlement_receipt_id: settlement_receipt.id)

          { boundary: boundary, summary_fact: summary_fact,
            metrics_fact: metrics_fact, settlement_receipt: settlement_receipt }
        end

        # Compact a settled boundary: marks detail_status :purged, writes cleanup receipt,
        # and writes one :ledger_fact_redirects entry per source_fact_id.
        # Settlement is required before compaction.
        # Returns the compaction receipt fact.
        def compact_boundary(boundary_key)
          boundary = @boundaries[boundary_key]
          raise ArgumentError, "boundary not found: #{boundary_key}"        unless boundary
          raise ArgumentError, "boundary must be closed before compaction"  unless boundary.status == :closed
          raise ArgumentError, "boundary must be settled before compaction" unless boundary.settled?

          compacted_at = Time.now.iso8601(3)

          compaction_receipt = @store.write(
            store:    :ledger_cleanup_receipts,
            key:      boundary_key,
            value:    {
              "boundary_key"          => boundary_key,
              "output_fact_id"        => boundary.output_fact_id,
              "result_hash"           => boundary.result_hash,
              "source_fact_ids"       => boundary.source_fact_ids,
              "source_fact_refs"      => boundary.source_fact_refs,
              "settlement_receipt_id" => boundary.settlement_receipt_id,
              "detail_status_after"   => "purged",
              "compacted_at"          => compacted_at
            },
            producer: PRODUCER
          )

          # Use structured refs when available (provides original_store + source_role).
          # Fall back to bare IDs with "unknown" store for old-style boundaries.
          if boundary.source_fact_refs.any?
            boundary.source_fact_refs.each do |ref|
              @store.write(
                store:    :ledger_fact_redirects,
                key:      ref["id"],
                value:    {
                  "original_fact_id"        => ref["id"],
                  "original_store"          => ref["store"],
                  "source_role"             => ref["role"],
                  "boundary_key"            => boundary_key,
                  "boundary_policy"         => LedgerBoundary::POLICY_NAME,
                  "boundary_output_fact_id" => boundary.output_fact_id,
                  "boundary_receipt_id"     => boundary.receipt_fact_id,
                  "settlement_receipt_id"   => boundary.settlement_receipt_id,
                  "compaction_receipt_id"   => compaction_receipt.id,
                  "detail_status"           => "purged",
                  "reference_role"          => "included_in_boundary",
                  "compacted_at"            => compacted_at
                },
                producer: PRODUCER
              )
            end
          else
            boundary.source_fact_ids.each do |src_id|
              @store.write(
                store:    :ledger_fact_redirects,
                key:      src_id,
                value:    {
                  "original_fact_id"        => src_id,
                  "original_store"          => "unknown",
                  "boundary_key"            => boundary_key,
                  "boundary_policy"         => LedgerBoundary::POLICY_NAME,
                  "boundary_output_fact_id" => boundary.output_fact_id,
                  "boundary_receipt_id"     => boundary.receipt_fact_id,
                  "settlement_receipt_id"   => boundary.settlement_receipt_id,
                  "compaction_receipt_id"   => compaction_receipt.id,
                  "detail_status"           => "purged",
                  "reference_role"          => "included_in_boundary",
                  "compacted_at"            => compacted_at
                },
                producer: PRODUCER
              )
            end
          end

          boundary.compact!(compaction_receipt_id: compaction_receipt.id)
          compaction_receipt
        end

        # Boundary replay: returns closed output without scanning source facts.
        # Works regardless of detail_status (even after compaction).
        #
        # Returns:
        #   { status: :ok, fidelity: :boundary, output:, boundary_id:, result_hash:, detail_status: }
        #   { status: :open,      boundary_key: }  — if boundary is still open
        #   { status: :not_found, boundary_key: }  — if boundary unknown
        def replay(boundary_key)
          boundary = @boundaries[boundary_key]
          return { status: :not_found, boundary_key: boundary_key } unless boundary
          return { status: :open,      boundary_key: boundary_key } unless boundary.closed?

          {
            status:        :ok,
            fidelity:      :boundary,
            output:        boundary.output_value,
            boundary_id:   boundary_key,
            result_hash:   boundary.result_hash,
            detail_status: boundary.detail_status
          }
        end

        # Full replay: uses all internal source facts.
        # After compaction returns :detail_unavailable.
        #
        # Returns:
        #   { status: :ok, fidelity: :full, output:, boundary_id:, detail_status: }
        #   { status: :detail_unavailable, boundary_id:, detail_status: :purged, boundary_receipt_id: }
        def full_replay(company_id:, technician_id:, date:, horizon_days: 1)
          boundary_key = LedgerBoundary.key_for(
            company_id:    company_id.to_s,
            technician_id: technician_id.to_s,
            date:          date.to_s
          )
          boundary = @boundaries[boundary_key]

          if boundary&.compacted?
            receipt_fact = @store.history(store: :ledger_boundary_receipts, key: boundary_key).last
            return {
              status:              :detail_unavailable,
              boundary_id:         boundary_key,
              detail_status:       :purged,
              boundary_receipt_id: receipt_fact&.id
            }
          end

          result = @ledger.compute_snapshot(
            technician_id: technician_id,
            horizon_start: coerce_date(date),
            horizon_days:  horizon_days
          )
          {
            status:        :ok,
            fidelity:      :full,
            output:        result[:snapshot_fact].value,
            boundary_id:   boundary_key,
            detail_status: boundary&.detail_status || :full
          }
        end

        # Returns a cleanup plan for a given store and time cutoff.
        #
        # :blocked — open boundaries, or closed-but-unsettled boundaries, in the window
        # :ready   — all required boundaries are settled; receipts listed for retention
        #
        # blocking_reasons maps each blocking boundary_key to its reason:
        #   :open                — boundary is still open
        #   :settlement_required — boundary is closed but not yet settled
        # Returns a cleanup plan for a given store and time cutoff.
        #
        # :blocked — open boundaries, closed-but-unsettled, or (when
        #   require_reference_redirects: true) settled boundaries whose source facts
        #   still have raw or unresolved external relation edges.
        # :ready   — all in-window boundaries are settled and no blocking reference
        #   edges remain.
        #
        # require_reference_redirects: (default false, preserving existing behavior)
        #   When true, the plan also checks :ledger_relation_edges. A settled boundary
        #   whose source facts are pointed at by raw or unresolved edges is blocked with
        #   reason :external_reference_redirect_required.
        def cleanup_plan(store:, before:, fidelity: :boundary, require_reference_redirects: false)
          in_window          = @boundaries.values.select { |b| boundary_date_before?(b, before) }
          open_blocking      = in_window.select(&:open?)
          unsettled_blocking = in_window.select { |b| b.status == :closed && !b.settled? }

          reference_blocking      = []
          blocking_relation_edges = []

          if require_reference_redirects
            in_window.select(&:settled?).each do |boundary|
              raw_edges = raw_external_edges_for(boundary)
              unless raw_edges.empty?
                reference_blocking << boundary
                blocking_relation_edges.concat(raw_edges.map { |e|
                  { edge_id:    e[:edge_id],
                    to_fact_id: e[:to_fact_id],
                    ref_status: e[:ref_status].to_s.to_sym,
                    boundary_key: boundary.boundary_key }
                })
              end
            end
          end

          all_blocking = open_blocking + unsettled_blocking + reference_blocking

          if all_blocking.empty?
            receipts = @boundaries.values.filter_map do |b|
              next unless b.closed?
              @store.history(store: :ledger_boundary_receipts, key: b.boundary_key).last&.id
            end
            result = {
              status:                      :ready,
              store:                       store,
              before:                      before.iso8601,
              fidelity:                    fidelity,
              require_reference_redirects: require_reference_redirects,
              blocking_boundaries:         [],
              required_boundary_policies:  [LedgerBoundary::POLICY_NAME.to_sym],
              receipts_to_keep:            receipts,
              expected_detail_status:      fidelity == :boundary ? :purged : :full
            }
            result[:blocking_relation_edges] = [] if require_reference_redirects
            result
          else
            blocking_reasons = {}
            open_blocking.each      { |b| blocking_reasons[b.boundary_key] = :open }
            unsettled_blocking.each { |b| blocking_reasons[b.boundary_key] = :settlement_required }
            reference_blocking.each { |b| blocking_reasons[b.boundary_key] = :external_reference_redirect_required }
            result = {
              status:                      :blocked,
              store:                       store,
              before:                      before.iso8601,
              fidelity:                    fidelity,
              require_reference_redirects: require_reference_redirects,
              blocking_boundaries:         all_blocking.map(&:boundary_key),
              blocking_reasons:            blocking_reasons,
              required_boundary_policies:  [LedgerBoundary::POLICY_NAME.to_sym]
            }
            result[:blocking_relation_edges] = blocking_relation_edges if require_reference_redirects
            result
          end
        end

        # Rebuilds the in-memory boundary registry from persisted store facts.
        #
        # Reads :ledger_boundaries, :ledger_boundary_receipts,
        # :ledger_settlement_receipts, and :ledger_cleanup_receipts to restore
        # boundary state. Recovers output_value by scanning :availability_snapshots
        # for the fact referenced by output_fact_id (linear scan — acceptable for proof).
        #
        # Idempotent: boundaries already in the registry are skipped.
        # Incomplete records (missing closure receipt) are skipped with a warning.
        #
        # Returns:
        #   { status: :ok, hydrated_count:, skipped_count:, warnings: [] }
        def hydrate_boundaries
          hydrated = 0
          skipped  = 0
          warnings = []

          @store.history(store: :ledger_boundaries)
            .group_by(&:key)
            .each do |bk, facts|
              next if @boundaries.key?(bk)

              br = facts.max_by(&:transaction_time).value

              closure_facts = @store.history(store: :ledger_boundary_receipts, key: bk)
              if closure_facts.empty?
                skipped  += 1
                warnings << "boundary #{bk}: closure receipt missing, skipped"
                next
              end

              settlement_facts      = @store.history(store: :ledger_settlement_receipts, key: bk)
              settlement_receipt_id = settlement_facts.empty? ? nil : settlement_facts.last.id

              cleanup_facts         = @store.history(store: :ledger_cleanup_receipts, key: bk)
              cleanup_receipt       = cleanup_facts.last
              compaction_receipt_id = cleanup_receipt&.id
              compacted_at          = cleanup_receipt \
                ? safe_parse_time(cleanup_receipt.value[:compacted_at]) : nil

              output_value = find_snapshot_value(br[:output_fact_id])

              boundary = LedgerBoundary.from_persisted(
                boundary_record:       br,
                output_value:          output_value,
                settlement_receipt_id: settlement_receipt_id,
                compaction_receipt_id: compaction_receipt_id,
                compacted_at:          compacted_at
              )

              @boundaries[bk] = boundary
              hydrated += 1
            end

          { status: :ok, hydrated_count: hydrated, skipped_count: skipped, warnings: warnings }
        end

        # Resolves a reference to a fact, respecting the required fidelity.
        #
        # fidelity:
        #   :raw      — return raw fact if accessible; never silently downgrade to boundary
        #               evidence. With assume_compacted: true (or when raw is physically
        #               absent), returns :detail_unavailable with redirect evidence.
        #   :boundary — intentionally follow redirect evidence when raw is compacted.
        #               Returns :redirected with boundary evidence.
        #   :summary  — like :boundary but marks kind: :summary_ref, signals settlement
        #               evidence is available via settlement_receipt_id in the redirect.
        #
        # assume_compacted: — for :raw fidelity only. When true, skips raw fact lookup
        #   and returns :detail_unavailable if a redirect exists. Useful in tests to
        #   simulate physical purge (which this proof does not perform).
        #
        # Returns one of:
        #   { status: :ok, kind: :raw_fact, fact: <Fact> }
        #   { status: :redirected, kind: :boundary_ref | :summary_ref, ... }
        #   { status: :detail_unavailable, original_fact_id:, boundary_key:,
        #     required_fidelity: :raw, available_fidelity: :boundary, evidence: }
        #   { status: :not_found, original_fact_id: }
        # Raises ArgumentError for unsupported fidelity values.
        def resolve_ref(fact_id, fidelity: :boundary, assume_compacted: false)
          unless %i[raw boundary summary].include?(fidelity)
            raise ArgumentError, "unsupported fidelity: #{fidelity.inspect}"
          end

          redirect = latest_redirect(fact_id)

          case fidelity
          when :raw
            return { status: :not_found, original_fact_id: fact_id } unless redirect
            return raw_detail_unavailable(fact_id, redirect)          if assume_compacted

            store_hint = redirect[:original_store]&.to_s
            raw_fact   = find_raw_fact(fact_id, store_hint: store_hint)
            raw_fact ? { status: :ok, kind: :raw_fact, fact: raw_fact }
                     : raw_detail_unavailable(fact_id, redirect)

          when :boundary
            return { status: :not_found, original_fact_id: fact_id } unless redirect
            boundary_redirect_response(fact_id, redirect)

          when :summary
            return { status: :not_found, original_fact_id: fact_id } unless redirect
            summary_redirect_response(fact_id, redirect)
          end
        end

        # Creates a relation edge from one fact to another, persisting compact metadata.
        #
        # Uses fact_ref(to_fact_id) to populate to_store/to_key from the live index.
        # If the target fact is unknown, the edge is persisted as :unresolved rather
        # than raising an exception.
        #
        # Returns: { edge_id:, edge_fact: }
        def link_fact(from_store:, from_key:, from_fact_id:, to_fact_id:, relation:)
          edge_id = SecureRandom.uuid
          to_ref  = @store.fact_ref(to_fact_id)

          value = if to_ref
            {
              "edge_id"         => edge_id,
              "relation"        => relation.to_s,
              "from_store"      => from_store.to_s,
              "from_key"        => from_key.to_s,
              "from_fact_id"    => from_fact_id.to_s,
              "to_store"        => to_ref[:store].to_s,
              "to_key"          => to_ref[:key].to_s,
              "to_fact_id"      => to_fact_id.to_s,
              "to_boundary_key" => nil,
              "ref_status"      => "raw",
              "fidelity"        => "raw",
              "evidence"        => {}
            }
          else
            {
              "edge_id"         => edge_id,
              "relation"        => relation.to_s,
              "from_store"      => from_store.to_s,
              "from_key"        => from_key.to_s,
              "from_fact_id"    => from_fact_id.to_s,
              "to_store"        => nil,
              "to_key"          => nil,
              "to_fact_id"      => to_fact_id.to_s,
              "to_boundary_key" => nil,
              "ref_status"      => "unresolved",
              "fidelity"        => "raw",
              "evidence"        => {}
            }
          end

          edge_fact = @store.write(
            store:    :ledger_relation_edges,
            key:      edge_id,
            value:    value,
            producer: PRODUCER
          )

          write_relation_edge_target(
            edge_id:        edge_id,
            to_fact_id:     to_fact_id.to_s,
            from_store:     from_store.to_s,
            from_fact_id:   from_fact_id.to_s,
            to_store:       value["to_store"],
            to_boundary_key: nil,
            ref_status:     value["ref_status"],
            relation:       relation.to_s,
            evidence:       {}
          )

          { edge_id: edge_id, edge_fact: edge_fact }
        end

        # Resolves a relation edge by edge_id, respecting the required fidelity.
        #
        # Delegates to resolve_ref semantics; maps results to edge vocabulary:
        #
        #   { status: :ok, ref_status: :raw, fidelity: :raw, to_fact: <Fact> }
        #   { status: :ok, ref_status: :redirected, fidelity: :boundary,
        #     to_boundary_key:, evidence: }
        #   { status: :detail_unavailable, to_fact_id:, evidence: }
        #   { status: :unresolved, ref_status: :unresolved, to_fact_id: }
        #   { status: :not_found, edge_id: }
        #
        # assume_compacted: — for :raw fidelity; skips live fact check, returns
        #   detail_unavailable when redirect exists.
        def resolve_edge(edge_id, fidelity: :boundary, assume_compacted: false)
          edge_facts = @store.history(store: :ledger_relation_edges, key: edge_id)
          return { status: :not_found, edge_id: edge_id } if edge_facts.empty?

          edge       = edge_facts.max_by(&:transaction_time).value
          to_fact_id = edge[:to_fact_id]

          return { status: :unresolved, ref_status: :unresolved, to_fact_id: to_fact_id } \
            if edge[:ref_status].to_s == "unresolved"

          # For :raw fidelity without assume_compacted, try live fact lookup first.
          # resolve_ref(:raw) requires a redirect to exist; edges must also resolve
          # when the raw fact is still live and no redirect has been written yet.
          if fidelity == :raw && !assume_compacted
            raw = @store.fact_by_id(to_fact_id)
            return { status: :ok, ref_status: :raw, fidelity: :raw, to_fact: raw } if raw
          end

          ref_result = resolve_ref(to_fact_id, fidelity: fidelity, assume_compacted: assume_compacted)

          case ref_result[:status]
          when :ok
            if ref_result[:kind] == :raw_fact
              { status: :ok, ref_status: :raw, fidelity: :raw, to_fact: ref_result[:fact] }
            else
              { status: :ok, ref_status: :redirected, fidelity: :boundary,
                to_boundary_key: ref_result[:boundary_key],
                evidence:        ref_result[:evidence] }
            end
          when :redirected
            { status: :ok, ref_status: :redirected, fidelity: :boundary,
              to_boundary_key: ref_result[:boundary_key],
              evidence:        ref_result[:evidence] }
          when :detail_unavailable
            { status: :detail_unavailable, to_fact_id: to_fact_id, evidence: ref_result[:evidence] }
          else
            { status: :unresolved, ref_status: :unresolved, to_fact_id: to_fact_id }
          end
        end

        # Scans all raw relation edges and updates those whose target fact has been
        # compacted (redirect evidence available) to ref_status: "redirected".
        #
        # assume_compacted: — when true, skips live fact check (simulates physical purge).
        # Idempotent: already-redirected and unresolved edges are skipped.
        #
        # Returns: { refreshed_count:, skipped_count:, unresolved_count: }
        def refresh_relation_edges(assume_compacted: false)
          refreshed  = 0
          skipped    = 0
          unresolved = 0

          @store.history(store: :ledger_relation_edges)
            .group_by(&:key)
            .each do |edge_id, facts|
              edge = facts.max_by(&:transaction_time).value
              next skipped += 1 unless edge[:ref_status].to_s == "raw"

              to_fact_id = edge[:to_fact_id]

              unless assume_compacted
                next skipped += 1 if @store.fact_by_id(to_fact_id)
              end

              redirect = latest_redirect(to_fact_id)
              next unresolved += 1 unless redirect

              evidence = {
                "boundary_output_fact_id" => redirect[:boundary_output_fact_id],
                "boundary_receipt_id"     => redirect[:boundary_receipt_id],
                "settlement_receipt_id"   => redirect[:settlement_receipt_id],
                "compaction_receipt_id"   => redirect[:compaction_receipt_id]
              }

              @store.write(
                store:    :ledger_relation_edges,
                key:      edge_id,
                value:    edge.transform_keys(&:to_s).merge(
                  "ref_status"      => "redirected",
                  "fidelity"        => "boundary",
                  "to_boundary_key" => redirect[:boundary_key],
                  "evidence"        => evidence,
                  "refreshed_at"    => Time.now.iso8601(3)
                ),
                producer: PRODUCER
              )

              write_relation_edge_target(
                edge_id:         edge_id,
                to_fact_id:      to_fact_id.to_s,
                from_store:      edge[:from_store].to_s,
                from_fact_id:    edge[:from_fact_id].to_s,
                to_store:        edge[:to_store]&.to_s,
                to_boundary_key: redirect[:boundary_key],
                ref_status:      "redirected",
                relation:        edge[:relation].to_s,
                evidence:        evidence
              )

              refreshed += 1
            end

          { refreshed_count: refreshed, skipped_count: skipped, unresolved_count: unresolved }
        end

        # Records a late fact for a closed boundary without mutating the original.
        # The original result_hash and settlement outputs remain unchanged.
        # Records boundary_status_at_arrival and settlement_status_at_arrival so
        # callers can see whether the boundary was settled or compacted at the time.
        # Returns the late-fact receipt.
        def write_late_fact(boundary_key:, fact_value:, fact_type:)
          boundary = @boundaries[boundary_key]
          raise ArgumentError, "boundary not found: #{boundary_key}" unless boundary
          raise ArgumentError, "boundary is not closed" unless boundary.closed?

          @store.write(
            store:    :late_fact_receipts,
            key:      "late/#{boundary_key}/#{SecureRandom.hex(8)}",
            value:    {
              "boundary_key"                  => boundary_key,
              "fact_type"                     => fact_type.to_s,
              "fact_value"                    => fact_value,
              "original_result_hash"          => boundary.result_hash,
              "boundary_status_at_arrival"    => boundary.status.to_s,
              "settlement_status_at_arrival"  => boundary.settlement_status.to_s,
              "recorded_at"                   => Time.now.iso8601(3),
              "disposition"                   => "correction_boundary"
            },
            producer: PRODUCER
          )
        end

        # Replays :ledger_relation_edges into :ledger_relation_edge_targets.
        # Use for recovery or proof setup when the target index is missing.
        # Safe to call on a live ledger — idempotent (appends latest state per edge).
        #
        # Returns: { rebuilt_count: }
        def rebuild_relation_edge_target_index
          rebuilt = 0
          @store.history(store: :ledger_relation_edges)
            .group_by(&:key)
            .each do |_edge_id, facts|
              edge = facts.max_by(&:transaction_time).value
              to_fact_id = (edge[:to_fact_id] || edge["to_fact_id"]).to_s
              next if to_fact_id.empty?

              write_relation_edge_target(
                edge_id:         (edge[:edge_id]   || edge["edge_id"]).to_s,
                to_fact_id:      to_fact_id,
                from_store:      (edge[:from_store] || edge["from_store"]).to_s,
                from_fact_id:    (edge[:from_fact_id] || edge["from_fact_id"]).to_s,
                to_store:        (edge[:to_store] || edge["to_store"])&.to_s,
                to_boundary_key: edge[:to_boundary_key] || edge["to_boundary_key"],
                ref_status:      (edge[:ref_status] || edge["ref_status"]).to_s,
                relation:        (edge[:relation]  || edge["relation"]).to_s,
                evidence:        edge[:evidence]   || edge["evidence"] || {}
              )
              rebuilt += 1
            end
          { rebuilt_count: rebuilt }
        end

        # Executes a ready cleanup plan and writes a durable receipt.
        #
        # For a ready plan:
        #   - Writes an executed_noop receipt to :ledger_cleanup_execution_receipts.
        #   - Is idempotent: a second call for the same plan returns deduplicated: true.
        #   - Returns { status: :executed_noop, plan_hash:, receipt_id:, deduplicated:, receipt: }.
        #
        # For a blocked plan:
        #   - Does not write a receipt.
        #   - Returns { status: :blocked, reason: :plan_not_ready, blocking_boundaries:,
        #     blocking_relation_edges: }.
        #
        # No physical deletion is performed in this slice.
        def execute_cleanup_plan(plan)
          unless plan[:status] == :ready
            return {
              status:                  :blocked,
              reason:                  :plan_not_ready,
              blocking_boundaries:     Array(plan[:blocking_boundaries]),
              blocking_relation_edges: Array(plan[:blocking_relation_edges])
            }
          end

          hash = stable_plan_hash(plan)

          # Idempotency check: return existing receipt when plan was already executed.
          existing = @store.history(store: :ledger_cleanup_execution_receipts, key: hash)
          unless existing.empty?
            receipt = existing.last
            return {
              status:       :executed_noop,
              plan_hash:    hash,
              receipt_id:   receipt.id,
              deduplicated: true,
              receipt:      receipt.value
            }
          end

          before_time    = Time.parse(plan[:before].to_s)
          in_window_keys = @boundaries.values
            .select { |b| boundary_date_before?(b, before_time) && b.closed? }
            .map(&:boundary_key)

          require_rr = plan.fetch(:require_reference_redirects, false)

          receipt_value = {
            "status"                        => "executed_noop",
            "plan_hash"                     => hash,
            "store"                         => plan[:store].to_s,
            "before"                        => plan[:before].to_s,
            "fidelity"                      => plan.fetch(:fidelity, :boundary).to_s,
            "require_reference_redirects"   => require_rr,
            "expected_detail_status"        => plan.fetch(:expected_detail_status, :purged).to_s,
            "boundary_keys"                 => in_window_keys,
            "receipts_to_keep"              => Array(plan[:receipts_to_keep]),
            "blocking_relation_edges_count" => 0,
            "relation_guard"                => {
              "checked"          => require_rr,
              "raw_edges"        => 0,
              "unresolved_edges" => 0,
              "redirected_edges" => 0
            },
            "executed_at"                   => Time.now.utc.iso8601(3)
          }

          fact = @store.write(
            store:    :ledger_cleanup_execution_receipts,
            key:      hash,
            value:    receipt_value,
            producer: PRODUCER
          )

          { status: :executed_noop, plan_hash: hash, receipt_id: fact.id,
            deduplicated: false, receipt: receipt_value }
        end

        # Physically purges boundary source facts from the store, provided all
        # safety rules pass.
        #
        # Safety rules (all must be true):
        #   - cleanup execution receipt exists with status == executed_noop
        #   - every boundary named in the receipt is compacted (logical purge done)
        #   - every source fact id has a redirect entry in :ledger_fact_redirects
        #   - the reference guard (require_reference_redirects: true) is still ready
        #   - the store backend supports exact fact pruning
        #
        # dry_run: true  — returns what would be pruned, no facts removed.
        # dry_run: false — calls store.prune_fact_ids and writes a physical purge receipt.
        #
        # Idempotent: second call for the same plan_hash returns deduplicated: true.
        #
        # Blocked reasons:
        #   :cleanup_execution_receipt_missing, :cleanup_execution_not_successful,
        #   :boundary_compaction_required, :fact_redirect_missing,
        #   :reference_guard_failed, :store_prune_unsupported
        def purge_cleanup_execution(plan_hash:, dry_run: false)
          # 1 — Find and validate the execution receipt
          exec_facts = @store.history(store: :ledger_cleanup_execution_receipts, key: plan_hash)
          unless exec_facts.any?
            return { status: :blocked, reason: :cleanup_execution_receipt_missing,
                     plan_hash: plan_hash }
          end

          exec_receipt = exec_facts.last.value
          unless exec_receipt[:status].to_s == "executed_noop"
            return { status: :blocked, reason: :cleanup_execution_not_successful,
                     plan_hash: plan_hash, receipt_status: exec_receipt[:status] }
          end

          # 2 — Validate each boundary: compacted? + all redirects present
          boundary_keys = Array(exec_receipt[:boundary_keys])
          source_fact_ids = []

          boundary_keys.each do |bk|
            boundary = @boundaries[bk]
            unless boundary&.compacted?
              return { status: :blocked, reason: :boundary_compaction_required,
                       boundary_key: bk }
            end

            boundary.source_fact_ids.each do |src_id|
              unless latest_redirect(src_id)
                return { status: :blocked, reason: :fact_redirect_missing,
                         fact_id: src_id, boundary_key: bk }
              end
              source_fact_ids << src_id
            end
          end

          # 3 — Re-run reference guard
          before_time = safe_parse_time(exec_receipt[:before])
          guard_plan  = cleanup_plan(
            store:                       (exec_receipt[:store] || "order_events").to_sym,
            before:                      before_time || Time.now,
            fidelity:                    (exec_receipt[:fidelity] || "boundary").to_sym,
            require_reference_redirects: exec_receipt[:require_reference_redirects]
          )

          if guard_plan[:status] != :ready
            return {
              status:                  :blocked,
              reason:                  :reference_guard_failed,
              blocking_boundaries:     guard_plan[:blocking_boundaries],
              blocking_relation_edges: Array(guard_plan[:blocking_relation_edges])
            }
          end

          fact_ids_to_prune = source_fact_ids.uniq

          # 4 — Dry run: return intent without any deletion
          if dry_run
            return {
              status:            :ready,
              dry_run:           true,
              fact_ids_to_prune: fact_ids_to_prune,
              boundary_keys:     boundary_keys,
              blockers:          []
            }
          end

          # 5 — Idempotency: existing purge receipt for this plan_hash
          existing_purge = @store.history(store: :ledger_physical_purge_receipts, key: plan_hash)
          if existing_purge.any?
            return {
              status:       :purged,
              deduplicated: true,
              plan_hash:    plan_hash,
              receipt_id:   existing_purge.last.id
            }
          end

          # 6 — Execute physical prune
          prune_result = @store.prune_fact_ids(
            fact_ids: fact_ids_to_prune,
            reason:   :boundary_physical_purge,
            metadata: {
              source:        "availability_boundary_ledger",
              plan_hash:     plan_hash,
              boundary_keys: boundary_keys
            }
          )

          if prune_result[:status] == :unsupported
            return { status: :blocked, reason: :store_prune_unsupported,
                     detail: prune_result }
          end

          # 7 — Write physical purge receipt
          purge_fact = @store.write(
            store:    :ledger_physical_purge_receipts,
            key:      plan_hash,
            value:    {
              "status"           => "purged",
              "plan_hash"        => plan_hash,
              "boundary_keys"    => boundary_keys,
              "fact_ids_pruned"  => fact_ids_to_prune,
              "pruned_count"     => prune_result[:pruned_count],
              "missing_count"    => prune_result[:missing_count],
              "prune_receipt_id" => prune_result[:receipt_id],
              "purged_at"        => Time.now.utc.iso8601(3)
            },
            producer: PRODUCER
          )

          {
            status:       :purged,
            deduplicated: false,
            plan_hash:    plan_hash,
            receipt_id:   purge_fact.id,
            pruned_count: prune_result[:pruned_count]
          }
        end

        # Normalized compaction activity for this ledger.
        # Delegates to the underlying store for retention compaction, exact prune,
        # and segment purge entries, then appends boundary physical purge receipts
        # from :ledger_physical_purge_receipts.
        def compaction_activity
          entries = @store.compaction_activity

          @store.history(store: :ledger_physical_purge_receipts).each do |f|
            v = f.value
            entries << {
              kind:        :boundary_physical_purge,
              executor:    :boundary_ledger,
              store:       nil,
              status:      (v["status"] || v[:status])&.to_sym || :purged,
              reason:      :boundary_physical_purge,
              fact_count:  (v["pruned_count"] || v[:pruned_count]).to_i,
              receipt_id:  f.id,
              occurred_at: f.transaction_time
            }
          end

          entries.sort_by { |e| e[:occurred_at] }
        end

        private

        # Returns the latest relation edge value for each blocking edge (raw or
        # unresolved) that targets one of the boundary's source facts.
        # Uses :ledger_relation_edge_targets index instead of scanning all history.
        def raw_external_edges_for(boundary)
          source_ids = boundary.source_fact_ids.map(&:to_s)
          return [] if source_ids.empty?

          source_ids.flat_map do |fact_id|
            @store.history(store: :ledger_relation_edge_targets, key: fact_id)
              .group_by { |f| (f.value[:edge_id] || f.value["edge_id"]).to_s }
              .filter_map do |_eid, facts|
                latest = facts.max_by(&:transaction_time).value
                next unless %w[raw unresolved].include?(latest[:ref_status].to_s)
                latest
              end
          end
        end

        # Writes a single entry to :ledger_relation_edge_targets.
        # Called on edge creation and on redirect; accumulates in history per to_fact_id.
        def write_relation_edge_target(edge_id:, to_fact_id:, from_store:, from_fact_id:,
                                       to_store:, to_boundary_key:, ref_status:, relation:, evidence:)
          @store.write(
            store:    :ledger_relation_edge_targets,
            key:      to_fact_id.to_s,
            value:    {
              "to_fact_id"      => to_fact_id.to_s,
              "edge_id"         => edge_id.to_s,
              "from_store"      => from_store.to_s,
              "from_fact_id"    => from_fact_id.to_s,
              "to_store"        => to_store&.to_s,
              "to_boundary_key" => to_boundary_key,
              "ref_status"      => ref_status.to_s,
              "relation"        => relation.to_s,
              "evidence"        => evidence || {}
            },
            producer: PRODUCER
          )
        end

        # Deterministic hash of cleanup plan identity, excluding volatile fields.
        # Used as the idempotency key for :ledger_cleanup_execution_receipts.
        def stable_plan_hash(plan)
          parts = [
            plan[:store].to_s,
            plan[:before].to_s,
            plan.fetch(:fidelity, :boundary).to_s,
            plan.fetch(:require_reference_redirects, false).to_s,
            Array(plan[:receipts_to_keep]).sort.join(",")
          ]
          Digest::SHA256.hexdigest(parts.join("|"))
        end

        def find_or_open_boundary(company_id:, technician_id:, date:)
          key = LedgerBoundary.key_for(
            company_id:    company_id.to_s,
            technician_id: technician_id.to_s,
            date:          date.to_s
          )
          @boundaries[key] || open_boundary(company_id: company_id, technician_id: technician_id, date: date)
        end

        def build_subject(company_id, technician_id, date)
          { company_id: company_id.to_s, technician_id: technician_id.to_s, date: date.to_s }
        end

        def coerce_date(date)
          date.is_a?(Date) ? date : Date.parse(date.to_s)
        end

        def boundary_date_before?(boundary, before)
          d = Date.parse(boundary.subject[:date].to_s)
          Time.utc(d.year, d.month, d.day) < before
        rescue ArgumentError
          false
        end

        # Returns the value of a snapshot fact by id using the store's fact-id index.
        # Rejects the result if the indexed fact is not from :availability_snapshots.
        def find_snapshot_value(fact_id)
          return nil unless fact_id
          fact = @store.fact_by_id(fact_id)
          return nil unless fact && fact.store == :availability_snapshots
          fact.value
        end

        def safe_parse_time(val)
          val ? Time.parse(val.to_s) : nil
        rescue ArgumentError, TypeError
          nil
        end

        def latest_redirect(fact_id)
          facts = @store.history(store: :ledger_fact_redirects, key: fact_id)
          facts.empty? ? nil : facts.max_by(&:transaction_time).value
        end

        # Returns the raw Fact for fact_id using the store's fact-id index.
        #
        # When store_hint is a known store name (from redirect provenance):
        #   return nil if the indexed fact is in a different store (mismatch rejection).
        # When store_hint is nil or "unknown":
        #   return the indexed fact regardless of store.
        def find_raw_fact(fact_id, store_hint: nil)
          return nil unless fact_id
          fact = @store.fact_by_id(fact_id)
          return nil unless fact
          if store_hint && store_hint != "unknown"
            return nil unless fact.store.to_s == store_hint
          end
          fact
        end

        def redirect_evidence(redirect)
          {
            boundary_output_fact_id: redirect[:boundary_output_fact_id],
            boundary_receipt_id:     redirect[:boundary_receipt_id],
            settlement_receipt_id:   redirect[:settlement_receipt_id],
            compaction_receipt_id:   redirect[:compaction_receipt_id]
          }
        end

        def raw_detail_unavailable(fact_id, redirect)
          {
            status:             :detail_unavailable,
            original_fact_id:   fact_id,
            boundary_key:       redirect[:boundary_key],
            required_fidelity:  :raw,
            available_fidelity: :boundary,
            evidence:           redirect_evidence(redirect)
          }
        end

        def boundary_redirect_response(fact_id, redirect)
          {
            status:           :redirected,
            kind:             :boundary_ref,
            original_fact_id: fact_id,
            boundary_key:     redirect[:boundary_key],
            detail_status:    :purged,
            evidence:         redirect_evidence(redirect)
          }
        end

        def summary_redirect_response(fact_id, redirect)
          {
            status:           :redirected,
            kind:             :summary_ref,
            original_fact_id: fact_id,
            boundary_key:     redirect[:boundary_key],
            detail_status:    :purged,
            evidence:         redirect_evidence(redirect)
          }
        end

        def boundary_record_value(boundary)
          {
            "boundary_key"     => boundary.boundary_key,
            "policy_name"      => LedgerBoundary::POLICY_NAME,
            "subject"          => boundary.subject.transform_keys(&:to_s),
            "status"           => boundary.status.to_s,
            "output_fact_id"   => boundary.output_fact_id,
            "receipt_fact_id"  => boundary.receipt_fact_id,
            "result_hash"      => boundary.result_hash,
            "source_fact_ids"  => boundary.source_fact_ids,
            "source_fact_refs" => boundary.source_fact_refs,
            "detail_status"    => boundary.detail_status.to_s,
            "closed_at"        => boundary.closed_at&.iso8601(3),
            "rule_version"     => LedgerBoundary::RULE_VERSION
          }
        end
      end
    end
  end
end
