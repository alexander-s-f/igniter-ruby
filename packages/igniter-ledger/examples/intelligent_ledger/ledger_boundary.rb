# frozen_string_literal: true

require "digest"
require "time"

module Igniter
  module Store
    module IntelligentLedger
      # A closed semantic boundary over facts for a technician availability day.
      #
      # Lifecycle: open -> closed -> settled -> compacted
      #
      # Once closed, result_hash and output_fact_id are immutable. Settlement
      # materialises useful long-lived memory (summary, metrics, receipt) before
      # compaction. Compaction requires settlement first, then marks internal
      # detail as purged while preserving output and result_hash.
      class LedgerBoundary
        POLICY_NAME  = "technician_day"
        RULE_VERSION = "1.0"

        attr_reader :boundary_key, :subject, :status, :result_hash,
                    :source_fact_ids, :source_fact_refs,
                    :output_fact_id, :output_value,
                    :receipt_fact_id, :detail_status, :closed_at,
                    :compacted_at, :compaction_receipt_id,
                    :settlement_status, :settlement_receipt_id

        def initialize(subject:, rule_version: RULE_VERSION)
          @subject       = subject.freeze
          @rule_version  = rule_version
          @boundary_key  = build_boundary_key
          @status        = :open
          @detail_status = :full
          @source_fact_ids       = [].freeze
          @source_fact_refs      = [].freeze
          @output_fact_id        = nil
          @output_value          = nil
          @receipt_fact_id       = nil
          @result_hash           = nil
          @closed_at             = nil
          @compacted_at          = nil
          @compaction_receipt_id = nil
          @settlement_status     = :unsettled
          @settlement_receipt_id = nil
        end

        def id = @boundary_key

        def open?      = @status == :open
        def closed?    = @status == :closed || @status == :compacted
        def compacted? = @status == :compacted
        def settled?   = @settlement_status == :settled

        # Transitions open -> closed.
        # output_fact, receipt_fact, result_hash are immutable after this point.
        # source_fact_refs — structured refs (id/store/role); optional, defaults to [].
        #   Refs are normalized to string keys for consistency across store round-trips.
        def close!(output_fact:, receipt_fact:, source_fact_ids:, source_fact_refs: [])
          raise "boundary already closed" unless @status == :open

          @output_fact_id  = output_fact.id
          @output_value    = output_fact.value
          @receipt_fact_id = receipt_fact.id
          @source_fact_ids = source_fact_ids.uniq.freeze
          @source_fact_refs = source_fact_refs
            .map { |r| r.transform_keys(&:to_s) }
            .uniq { |r| r["id"] }
            .freeze
          @result_hash     = compute_result_hash(@output_value, @source_fact_ids)
          @status          = :closed
          @closed_at       = Time.now
        end

        # Transitions settlement_status: :unsettled -> :settled.
        # Boundary must be closed first. settlement_receipt_id is immutable after this.
        def settle!(settlement_receipt_id:)
          raise "boundary must be closed before settlement" unless @status == :closed
          raise "boundary already settled"                  if @settlement_status == :settled

          @settlement_receipt_id = settlement_receipt_id
          @settlement_status     = :settled
        end

        # Transitions closed -> compacted.
        # Requires settlement first. Internal detail is marked purged;
        # output, result_hash, and settlement outputs remain intact.
        def compact!(compaction_receipt_id:)
          raise "boundary must be closed before compaction"   unless @status == :closed
          raise "boundary must be settled before compaction"  unless @settlement_status == :settled

          @compaction_receipt_id = compaction_receipt_id
          @detail_status         = :purged
          @status                = :compacted
          @compacted_at          = Time.now
        end

        # Returns a class-level deterministic key without instantiating a full boundary.
        def self.key_for(company_id:, technician_id:, date:, rule_version: RULE_VERSION)
          "#{POLICY_NAME}/company=#{company_id}/technician=#{technician_id}/date=#{date}/version=#{rule_version}"
        end

        # Rebuilds a LedgerBoundary from persisted store data after a process restart.
        #
        # boundary_record      — value hash from :ledger_boundaries (symbol keys from store)
        # output_value         — value hash recovered from :availability_snapshots, or nil
        # settlement_receipt_id — fact ID from :ledger_settlement_receipts, nil if unsettled
        # compaction_receipt_id — fact ID from :ledger_cleanup_receipts, nil if not compacted
        # compacted_at          — parsed Time from cleanup receipt, nil if not compacted
        #
        # Status is authoritative from receipt evidence: if compaction_receipt_id is present
        # the status is :compacted regardless of what the boundary record says, because the
        # boundary record in :ledger_boundaries is written at close time and never updated.
        def self.from_persisted(boundary_record:, output_value: nil,
                                settlement_receipt_id: nil,
                                compaction_receipt_id: nil,
                                compacted_at: nil)
          obj = allocate
          obj.__send__(:restore_from_record!,
                       boundary_record:       boundary_record,
                       output_value:          output_value,
                       settlement_receipt_id: settlement_receipt_id,
                       compaction_receipt_id: compaction_receipt_id,
                       compacted_at:          compacted_at)
          obj
        end

        private

        def restore_from_record!(boundary_record:, output_value:,
                                 settlement_receipt_id:, compaction_receipt_id:, compacted_at:)
          @boundary_key = boundary_record[:boundary_key]
          @rule_version = boundary_record[:rule_version] || RULE_VERSION
          @subject      = boundary_record[:subject].freeze

          # Status: cleanup receipt evidence overrides the stored boundary status
          # (boundary record is written at close time and never updated on compact)
          @status       = compaction_receipt_id ? :compacted : :closed
          @detail_status = compaction_receipt_id ? :purged : (boundary_record[:detail_status]&.to_sym || :full)

          @output_fact_id  = boundary_record[:output_fact_id]
          @output_value    = output_value
          @receipt_fact_id = boundary_record[:receipt_fact_id]
          @result_hash     = boundary_record[:result_hash]
          @source_fact_ids  = Array(boundary_record[:source_fact_ids]).freeze
          @source_fact_refs = Array(boundary_record[:source_fact_refs] || [])
            .map { |r| r.transform_keys(&:to_s) }
            .freeze

          @closed_at             = parse_time_safe(boundary_record[:closed_at])
          @compacted_at          = compacted_at
          @compaction_receipt_id = compaction_receipt_id

          @settlement_status     = settlement_receipt_id ? :settled : :unsettled
          @settlement_receipt_id = settlement_receipt_id
        end

        def parse_time_safe(val)
          val ? Time.parse(val.to_s) : nil
        rescue ArgumentError, TypeError
          nil
        end

        def build_boundary_key
          s = @subject
          self.class.key_for(
            company_id:    s[:company_id],
            technician_id: s[:technician_id],
            date:          s[:date],
            rule_version:  @rule_version
          )
        end

        def compute_result_hash(output_value, source_fact_ids)
          content = output_value.to_s + source_fact_ids.sort.join(",") + @rule_version
          Digest::SHA256.hexdigest(content)
        end
      end
    end
  end
end
