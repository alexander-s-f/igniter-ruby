# frozen_string_literal: true

require "securerandom"
require "time"

module Igniter
  module Store
    # Thread-safe metrics and telemetry collector for StoreServer.
    #
    # Tracks counters (requests, errors, bytes, facts), per-connection records,
    # subscription counts, and fires in-process alerts when configurable thresholds
    # are exceeded.
    #
    # Usage:
    #   metrics = ServerMetrics.new(thresholds: { max_connections: 200 })
    #   id = metrics.record_connection_accepted(remote_addr: "10.0.0.1")
    #   metrics.record_request(connection_id: id, op: "write_fact", bytes_in: 64, bytes_out: 16)
    #   metrics.record_connection_closed(id: id)
    #   snap = metrics.snapshot
    class ServerMetrics
      ConnectionRecord = Struct.new(
        :connection_id, :accepted_at, :closed_at,
        :remote_addr, :ops_count, :bytes_in, :bytes_out,
        :last_op, :close_reason,
        keyword_init: true
      )

      Alert = Struct.new(
        :id, :fired_at, :type, :threshold, :current_value, :message,
        keyword_init: true
      )

      DEFAULT_THRESHOLDS = {
        max_connections:          500,
        error_rate:               0.1,
        replay_size:              10_000,
        quarantine_receipt_count: 10,
        storage_byte_size:        1_073_741_824,
        slow_op_count:            nil   # nil = disabled; set to an integer to enable
      }.freeze

      def initialize(thresholds: {})
        @mutex               = Mutex.new
        @thresholds          = DEFAULT_THRESHOLDS.merge(thresholds)
        @started_at          = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @facts_written       = 0
        @facts_replayed      = 0
        @bytes_in            = 0
        @bytes_out           = 0
        @requests_total      = Hash.new(0)
        @errors_total        = Hash.new(0)
        @slow_ops_total      = Hash.new(0)
        @accepted_total      = 0
        @closed_total        = 0
        @rejected_total      = 0
        @active_conns        = {}
        @subscription_counts = Hash.new(0)
        @alerts              = []
      end

      # Records a new connection. Returns the connection_id string.
      def record_connection_accepted(remote_addr:)
        id  = SecureRandom.hex(8)
        rec = ConnectionRecord.new(
          connection_id: id,
          accepted_at:   Time.now,
          closed_at:     nil,
          remote_addr:   remote_addr.to_s,
          ops_count:     0,
          bytes_in:      0,
          bytes_out:     0,
          last_op:       nil,
          close_reason:  nil
        )
        @mutex.synchronize { @active_conns[id] = rec; @accepted_total += 1 }
        id
      end

      def record_connection_closed(id:, reason: nil)
        @mutex.synchronize do
          rec = @active_conns.delete(id)
          if rec
            rec.closed_at    = Time.now
            rec.close_reason = reason
          end
          @closed_total += 1
        end
      end

      def record_connection_rejected
        @mutex.synchronize { @rejected_total += 1 }
      end

      # Records one request dispatched on a connection.
      def record_request(connection_id:, op:, bytes_in: 0, bytes_out: 0)
        op_s = op.to_s
        @mutex.synchronize do
          @requests_total[op_s] += 1
          @bytes_in  += bytes_in.to_i
          @bytes_out += bytes_out.to_i
          rec = @active_conns[connection_id]
          if rec
            rec.ops_count += 1
            rec.bytes_in  += bytes_in.to_i
            rec.bytes_out += bytes_out.to_i
            rec.last_op    = op_s
          end
        end
      end

      def record_error(op:, error_class:)
        key = "#{error_class}/#{op}"
        @mutex.synchronize { @errors_total[key] += 1 }
      end

      def record_slow_op(op:)
        @mutex.synchronize { @slow_ops_total[op.to_s] += 1 }
      end

      def record_facts_written(count: 1)
        @mutex.synchronize { @facts_written += count }
      end

      def record_facts_replayed(count:)
        @mutex.synchronize { @facts_replayed += count }
      end

      def record_subscription_opened(store:)
        @mutex.synchronize { @subscription_counts[store.to_s] += 1 }
      end

      def record_subscription_closed(store:)
        @mutex.synchronize do
          s = store.to_s
          @subscription_counts[s] = [@subscription_counts[s] - 1, 0].max
        end
      end

      # Returns a frozen snapshot Hash of all current metrics.
      # +backend:+ is optional — if the backend supports storage_stats, it is included.
      def snapshot(backend: nil)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @mutex.synchronize do
          storage = backend.respond_to?(:storage_stats) ? (backend.storage_stats rescue nil) : nil
          {
            schema_version:             1,
            generated_at:               Time.now.iso8601(3),
            uptime_ms:                  ((now - @started_at) * 1000).ceil,
            facts_written:              @facts_written,
            facts_replayed:             @facts_replayed,
            bytes_in:                   @bytes_in,
            bytes_out:                  @bytes_out,
            requests_total:             @requests_total.dup,
            errors_total:               @errors_total.dup,
            slow_ops_total:             @slow_ops_total.dup,
            active_connections:         @active_conns.size,
            accepted_connections_total: @accepted_total,
            closed_connections_total:   @closed_total,
            rejected_connections_total: @rejected_total,
            subscription_count:         @subscription_counts.values.sum,
            subscriptions_by_store:     @subscription_counts.dup,
            storage_stats:              storage,
            alerts:                     @alerts.map(&:to_h)
          }
        end
      end

      # Evaluates alert thresholds and fires new alerts when breached.
      # Already-fired alerts are not re-fired (no alert storms).
      # Returns the current alerts Array.
      def check_alerts(backend: nil)
        @mutex.synchronize do
          fire_alert(:max_connections, @active_conns.size)
          total_req = @requests_total.values.sum
          if total_req.positive?
            total_err = @errors_total.values.sum
            fire_alert(:error_rate, total_err.to_f / total_req)
          end
          if backend.respond_to?(:storage_stats)
            begin
              stats = backend.storage_stats
              if stats
                qc = stats["stores"]&.values&.sum { |s| s["quarantine_receipt_count"].to_i } || 0
                fire_alert(:quarantine_receipt_count, qc)
                bs = stats["stores"]&.values&.sum { |s| s["byte_size"].to_i } || 0
                fire_alert(:storage_byte_size, bs)
              end
            rescue StandardError
              nil
            end
          end

          total_slow = @slow_ops_total.values.sum
          fire_alert(:slow_op_count, total_slow) if total_slow.positive?
        end
        @mutex.synchronize { @alerts.dup }
      end

      def alerts
        @mutex.synchronize { @alerts.dup }
      end

      private

      def fire_alert(type, current)
        threshold = @thresholds[type]
        return unless threshold
        return unless current > threshold
        return if @alerts.any? { |a| a.type == type }

        @alerts << Alert.new(
          id:            SecureRandom.hex(6),
          fired_at:      Time.now,
          type:          type,
          threshold:     threshold,
          current_value: current,
          message:       "#{type} exceeded threshold: #{current} > #{threshold}"
        )
      end
    end
  end
end
