# frozen_string_literal: true

require "securerandom"

module Igniter
  module Store
    # Bounded in-memory Changefeed buffer with async per-subscriber fan-out,
    # delivery policies, and production diagnostics.
    #
    # Receives committed facts via +emit+, builds ChangeEvent objects with
    # monotonic sequence cursors, retains recent events in a bounded ring, and
    # fans out to registered subscriber handlers via per-subscriber bounded
    # queues and worker threads so that slow subscribers never stall +emit+.
    #
    # Delivery semantics: async best-effort push.
    # - Fan-out enqueues to a per-subscriber SubscriberQueue; emit returns quickly.
    # - Each subscriber has one worker thread draining its queue.
    # - When a subscriber queue is full, overflow policy determines which event
    #   is dropped (see +overflow:+ option).
    # - A handler that raises is removed, counted as failed, and its worker exits.
    # - When the ring is full the oldest retained event is dropped and
    #   +dropped_total+ is incremented.
    # - No durable checkpoints in this v0 slice.
    #
    # Overflow policies (subscriber queue full):
    # - +:drop_oldest+ — remove the oldest queued event; add the incoming event.
    # - +:drop_newest+ — discard the incoming event; queue unchanged.
    #
    # Close policies (Subscription#close):
    # - +:drain+    — deliver all queued events before stopping the worker.
    # - +:discard+  — clear the queue immediately; worker exits after current event.
    #
    # Alert thresholds (optional, checked at each #snapshot call):
    # - +:failed_total+           — fires :changefeed_subscriber_failures
    # - +:overflow_dropped_total+ — fires :changefeed_overflow_drops
    # - +:total_queued+           — fires :changefeed_queue_pressure (aggregate)
    # - +:queue_pressure_ratio+   — fires :changefeed_queue_pressure (per-subscriber)
    #
    # Diagnostics ring records bounded lifecycle/failure events:
    # - :subscriber_subscribed / :subscriber_closed / :subscriber_failed
    # - :subscriber_overflow
    #
    # Ordering policy:
    # - Sequences are assigned in emit-call order (monotonically increasing).
    # - IgniterStore emits the source fact BEFORE triggering derivations/scatters,
    #   so subscribers always see cause before effects within their queue.
    #
    # Replay cursor semantics (see #replay):
    # - nil cursor    → all retained events from oldest retained sequence.
    # - {sequence: N} → events with sequence > N.
    # - N < oldest-1  → :cursor_too_old (gap due to ring overflow).
    # - N >= newest   → empty :ok (caller is already at the head).
    #
    # Usage:
    #   buf    = ChangefeedBuffer.new(max_size: 1_000)
    #   handle = buf.subscribe(stores: [:tasks]) { |event| deliver(event) }
    #   buf.emit(fact)      # enqueues to matching subscriber queues; returns quickly
    #   handle.close        # respects close_policy (drain or discard), joins worker
    class ChangefeedBuffer
      DEFAULT_MAX_SIZE              = 1_000
      DEFAULT_SUBSCRIBER_QUEUE_SIZE = 100
      DEFAULT_OVERFLOW              = :drop_oldest
      DEFAULT_CLOSE_POLICY          = :drain
      DEFAULT_DIAGNOSTIC_RING_SIZE  = 100

      VALID_OVERFLOW_POLICIES = %i[drop_oldest drop_newest].freeze
      VALID_CLOSE_POLICIES    = %i[drain discard].freeze
      VALID_THRESHOLD_KEYS    = %i[total_queued overflow_dropped_total failed_total queue_pressure_ratio].freeze

      # Bounded FIFO queue for one subscriber's async delivery pipeline.
      #
      # +push+ is non-blocking and returns +true+ when an overflow drop occurs.
      # +pop+ blocks until an event is available or the queue is closed.
      # Once closed, +pop+ drains remaining items (unless discard was requested)
      # then returns +nil+.
      class SubscriberQueue
        def initialize(max_size:, overflow: :drop_oldest)
          @max_size = max_size
          @overflow = overflow
          @items    = []
          @mu       = Mutex.new
          @cond     = ConditionVariable.new
          @closed   = false
        end

        # Returns +true+ if an overflow drop occurred, +false+ otherwise.
        def push(event)
          @mu.synchronize do
            return false if @closed
            if @items.size >= @max_size
              case @overflow
              when :drop_oldest
                @items.shift
                @items << event
                @cond.signal
              when :drop_newest
                # discard the incoming event; queue unchanged
              end
              return true
            end
            @items << event
            @cond.signal
            false
          end
        end

        # Blocks until next event or close signal. Returns nil when closed+drained.
        def pop
          @mu.synchronize do
            @cond.wait(@mu) while @items.empty? && !@closed
            @items.shift
          end
        end

        # Pass +discard: true+ to clear queued events before signaling close.
        def close(discard: false)
          @mu.synchronize do
            @items.clear if discard
            @closed = true
            @cond.broadcast
          end
        end

        def size
          @mu.synchronize { @items.size }
        end
      end

      # Bounded ring buffer for structured diagnostic entries.
      # All push/snapshot operations are thread-safe.
      # Oldest entries are evicted when +max_size+ is exceeded;
      # +dropped_diagnostics_total+ counts evictions.
      class DiagnosticRing
        def initialize(max_size)
          @max_size  = max_size
          @entries   = []
          @mu        = Mutex.new
          @total     = 0
          @dropped   = 0
        end

        def push(entry)
          @mu.synchronize do
            @total += 1
            if @entries.size >= @max_size
              @entries.shift
              @dropped += 1
            end
            @entries << entry
          end
        end

        def snapshot
          @mu.synchronize do
            {
              recent:                    @entries.dup,
              recent_count:              @total,
              dropped_diagnostics_total: @dropped
            }
          end
        end
      end

      # Returned by #subscribe. Call #close to stop delivery and release resources.
      # Close behavior is governed by the buffer's +close_policy+:
      # - +:drain+   — pending events are delivered before worker stops.
      # - +:discard+ — pending events are dropped; worker stops after current event.
      # Calling #close is idempotent.
      class Subscription
        def initialize(record, buffer)
          @record = record
          @buffer = buffer
        end

        def close
          @buffer.__send__(:remove_record, @record)
          @record.thread&.join(2) rescue nil
        end
      end

      SubscriptionRecord = Struct.new(
        :id, :stores, :handler, :queue, :thread,
        :overflow, :close_policy,
        :delivered_total, :overflow_dropped_total, :failed_total,
        :status,
        keyword_init: true
      )

      def initialize(max_size: DEFAULT_MAX_SIZE,
                     subscriber_queue_size: DEFAULT_SUBSCRIBER_QUEUE_SIZE,
                     overflow: DEFAULT_OVERFLOW,
                     close_policy: DEFAULT_CLOSE_POLICY,
                     diagnostic_ring_size: DEFAULT_DIAGNOSTIC_RING_SIZE,
                     alert_thresholds: {})
        unless VALID_OVERFLOW_POLICIES.include?(overflow)
          raise ArgumentError, "unknown overflow policy: #{overflow.inspect}. " \
                               "Valid: #{VALID_OVERFLOW_POLICIES.map(&:inspect).join(", ")}"
        end
        unless VALID_CLOSE_POLICIES.include?(close_policy)
          raise ArgumentError, "unknown close_policy: #{close_policy.inspect}. " \
                               "Valid: #{VALID_CLOSE_POLICIES.map(&:inspect).join(", ")}"
        end

        thresholds = (alert_thresholds || {}).transform_keys(&:to_sym)
        unknown    = thresholds.keys - VALID_THRESHOLD_KEYS
        unless unknown.empty?
          raise ArgumentError, "unknown alert_threshold keys: #{unknown.map(&:inspect).join(", ")}. " \
                               "Valid: #{VALID_THRESHOLD_KEYS.map(&:inspect).join(", ")}"
        end

        unless max_size.is_a?(Integer) && max_size > 0
          raise ArgumentError, "max_size must be a positive integer, got #{max_size.inspect}"
        end
        unless subscriber_queue_size.is_a?(Integer) && subscriber_queue_size > 0
          raise ArgumentError, "subscriber_queue_size must be a positive integer, got #{subscriber_queue_size.inspect}"
        end
        unless diagnostic_ring_size.is_a?(Integer) && diagnostic_ring_size > 0
          raise ArgumentError, "diagnostic_ring_size must be a positive integer, got #{diagnostic_ring_size.inspect}"
        end
        ratio = thresholds[:queue_pressure_ratio]
        if ratio && !(ratio.is_a?(Numeric) && ratio >= 0.0 && ratio <= 1.0)
          raise ArgumentError, "queue_pressure_ratio must be between 0.0 and 1.0, got #{ratio.inspect}"
        end

        @max_size               = max_size
        @subscriber_queue_size  = subscriber_queue_size
        @overflow               = overflow
        @close_policy           = close_policy
        @alert_thresholds       = thresholds
        @diagnostics            = DiagnosticRing.new(diagnostic_ring_size)
        @ring                   = []
        @records                = []
        @mutex                  = Mutex.new
        @sequence               = 0
        @emitted_total          = 0
        @delivered_total        = 0
        @dropped_total          = 0
        @overflow_dropped_total = 0
        @failed_total           = 0
      end

      # Register a subscriber handler for one or more store names.
      # +stores:+ — Array of store name symbols/strings, or [] for all stores (wildcard).
      # Returns a Subscription handle; call handle.close to unsubscribe.
      def subscribe(stores:, &handler)
        raise ArgumentError, "subscribe requires a block" unless handler

        q = SubscriberQueue.new(max_size: @subscriber_queue_size, overflow: @overflow)
        record = SubscriptionRecord.new(
          id:                     SecureRandom.hex(8),
          stores:                 Array(stores).map(&:to_s),
          handler:                handler,
          queue:                  q,
          thread:                 nil,
          overflow:               @overflow,
          close_policy:           @close_policy,
          delivered_total:        0,
          overflow_dropped_total: 0,
          failed_total:           0,
          status:                 :active
        )

        thread = Thread.new do
          loop do
            event = q.pop
            break if event.nil?
            begin
              handler.call(event)
              @mutex.synchronize do
                @delivered_total += 1
                record.delivered_total += 1
              end
            rescue StandardError => e
              ts = Process.clock_gettime(Process::CLOCK_REALTIME)
              @mutex.synchronize do
                @failed_total += 1
                record.failed_total += 1
                record.status = :failed
              end
              @diagnostics.push({
                type:          :subscriber_failed,
                subscriber_id: record.id,
                stores:        record.stores,
                error_class:   e.class.name,
                message:       e.message.to_s.slice(0, 200),
                ts:            ts
              })
              remove_record(record, record_diagnostic: false)
              break
            end
          end
        end
        record.thread = thread

        @mutex.synchronize { @records << record }
        @diagnostics.push({
          type:          :subscriber_subscribed,
          subscriber_id: record.id,
          stores:        record.stores,
          ts:            Process.clock_gettime(Process::CLOCK_REALTIME)
        })

        Subscription.new(record, self)
      end

      # Build a ChangeEvent from +fact+, add to the ring buffer, and enqueue to
      # matching subscriber queues. Returns the emitted ChangeEvent immediately.
      def emit(fact)
        event = @mutex.synchronize do
          @sequence += 1
          e = ChangeEvent.from_fact(fact, sequence: @sequence)
          @emitted_total += 1
          if @ring.size >= @max_size
            @ring.shift
            @dropped_total += 1
          end
          @ring << e
          e
        end

        fan_out(event)
        event
      end

      # Number of active subscribers, optionally filtered by store name.
      # Wildcard subscribers (stores == []) are counted for every store.
      def subscriber_count(store = nil)
        @mutex.synchronize do
          if store
            @records.count { |r| r.stores.empty? || r.stores.include?(store.to_s) }
          else
            @records.size
          end
        end
      end

      # Replay retained ChangeEvents from the in-memory ring.
      #
      # +cursor+  — nil or { sequence: Integer }
      # +stores+  — nil (all) or Array of store name symbols/strings to filter
      # +limit+   — nil (all matching) or Integer cap on returned events
      #
      # Returns a Hash:
      #   {
      #     status:        :ok | :cursor_too_old,
      #     events:        [ChangeEvent, ...],
      #     cursor:        { sequence: N } | nil,
      #     oldest_cursor: { sequence: N } | nil,
      #     newest_cursor: { sequence: N } | nil,
      #     dropped_total: Integer
      #   }
      def replay(cursor: nil, stores: nil, limit: nil)
        @mutex.synchronize do
          if @ring.empty?
            return {
              status:        :ok,
              events:        [],
              cursor:        nil,
              oldest_cursor: nil,
              newest_cursor: nil,
              dropped_total: @dropped_total
            }
          end

          oldest_seq = @ring.first.cursor[:sequence]
          newest_seq = @ring.last.cursor[:sequence]

          candidates =
            if cursor.nil?
              @ring.dup
            else
              req_seq = Integer(cursor[:sequence])

              if req_seq < oldest_seq - 1
                return {
                  status:        :cursor_too_old,
                  events:        [],
                  cursor:        { sequence: newest_seq },
                  oldest_cursor: { sequence: oldest_seq },
                  newest_cursor: { sequence: newest_seq },
                  dropped_total: @dropped_total
                }
              end

              if req_seq >= newest_seq
                return {
                  status:        :ok,
                  events:        [],
                  cursor:        { sequence: newest_seq },
                  oldest_cursor: { sequence: oldest_seq },
                  newest_cursor: { sequence: newest_seq },
                  dropped_total: @dropped_total
                }
              end

              @ring.select { |e| e.cursor[:sequence] > req_seq }
            end

          if stores && !stores.empty?
            store_strs = Array(stores).map(&:to_s)
            candidates = candidates.select { |e| store_strs.include?(e.store.to_s) }
          end

          candidates = candidates.first(limit) if limit

          result_cursor =
            if candidates.last
              { sequence: candidates.last.cursor[:sequence] }
            else
              { sequence: newest_seq }
            end

          {
            status:        :ok,
            events:        candidates,
            cursor:        result_cursor,
            oldest_cursor: { sequence: oldest_seq },
            newest_cursor: { sequence: newest_seq },
            dropped_total: @dropped_total
          }
        end
      end

      # Compact snapshot of current changefeed state for observability.
      # Includes +alerts+ (evaluated against configured thresholds) and
      # +diagnostics+ (recent bounded ring of lifecycle/failure entries).
      #
      # +dropped_total+          — retained ring drops (ring full)
      # +overflow_dropped_total+ — subscriber queue drops (slow consumer)
      # +total_queued+           — sum of all active subscriber queue sizes (backpressure)
      def snapshot
        @mutex.synchronize do
          total_queued = @records.sum { |r| r.queue.size }
          current = {
            emitted_total:          @emitted_total,
            delivered_total:        @delivered_total,
            dropped_total:          @dropped_total,
            overflow_dropped_total: @overflow_dropped_total,
            failed_total:           @failed_total,
            buffered:               @ring.size,
            max_size:               @max_size,
            subscriber_count:       @records.size,
            subscriber_queue_size:  @subscriber_queue_size,
            overflow:               @overflow,
            close_policy:           @close_policy,
            total_queued:           total_queued,
            oldest_sequence:        @ring.first&.cursor&.fetch(:sequence, nil),
            newest_sequence:        @ring.last&.cursor&.fetch(:sequence, nil)
          }
          current[:alerts]      = compute_alerts(current)
          current[:diagnostics] = @diagnostics.snapshot
          current
        end
      end

      # Per-subscriber state snapshot for diagnosing slow/failing consumers.
      #
      # Returns an Array of Hashes — one per active subscriber — with fields:
      #   id, stores, queue_size, queue_max_size, overflow, close_policy,
      #   status, delivered_total, overflow_dropped_total, failed_total
      #
      # Subscribers that have already failed or been closed are not listed.
      def subscriber_snapshot
        @mutex.synchronize do
          @records.map do |r|
            {
              id:                     r.id,
              stores:                 r.stores,
              queue_size:             r.queue.size,
              queue_max_size:         @subscriber_queue_size,
              overflow:               r.overflow,
              close_policy:           r.close_policy,
              status:                 r.status,
              delivered_total:        r.delivered_total,
              overflow_dropped_total: r.overflow_dropped_total,
              failed_total:           r.failed_total
            }
          end
        end
      end

      protected

      # Removes +record+ from the active list and closes its queue.
      # Respects the record's +close_policy+ (:drain or :discard).
      # Does not join the worker thread — safe to call from inside the worker.
      # Subscription#close handles the join for external callers.
      #
      # +record_diagnostic:+ — when true (default), records a :subscriber_closed
      # diagnostic entry. Pass false when the caller has already recorded a more
      # specific entry (e.g., :subscriber_failed from the worker rescue block).
      def remove_record(record, record_diagnostic: true)
        return unless record
        @mutex.synchronize { @records.reject! { |r| r.equal?(record) } }
        record.queue&.close(discard: record.close_policy == :discard)
        return unless record_diagnostic
        @diagnostics.push({
          type:          :subscriber_closed,
          subscriber_id: record.id,
          stores:        record.stores,
          ts:            Process.clock_gettime(Process::CLOCK_REALTIME)
        })
      end

      private

      def fan_out(event)
        store_s  = event.store.to_s
        matching = @mutex.synchronize {
          @records.select { |r| r.stores.empty? || r.stores.include?(store_s) }.dup
        }
        overflow_records = []
        matching.each do |record|
          overflow_records << record if record.queue.push(event)
        end
        unless overflow_records.empty?
          @mutex.synchronize do
            overflow_records.each do |r|
              @overflow_dropped_total += 1
              r.overflow_dropped_total += 1
            end
          end
          ts = Process.clock_gettime(Process::CLOCK_REALTIME)
          overflow_records.each do |r|
            @diagnostics.push({
              type:          :subscriber_overflow,
              subscriber_id: r.id,
              ts:            ts
            })
          end
        end
      end

      # Evaluate configured alert thresholds against the current snapshot values.
      # Called from within #snapshot while @mutex is held.
      # Per-subscriber ratio alert accesses subscriber queue sizes (safe by lock order).
      def compute_alerts(snap)
        alerts = []

        if (t = @alert_thresholds[:failed_total]) && snap[:failed_total] >= t
          alerts << {
            code:      :changefeed_subscriber_failures,
            severity:  :warning,
            value:     snap[:failed_total],
            threshold: t
          }
        end

        if (t = @alert_thresholds[:overflow_dropped_total]) && snap[:overflow_dropped_total] >= t
          alerts << {
            code:      :changefeed_overflow_drops,
            severity:  :warning,
            value:     snap[:overflow_dropped_total],
            threshold: t
          }
        end

        if (t = @alert_thresholds[:total_queued]) && snap[:total_queued] >= t
          alerts << {
            code:      :changefeed_queue_pressure,
            severity:  :warning,
            value:     snap[:total_queued],
            threshold: t
          }
        end

        if (ratio_t = @alert_thresholds[:queue_pressure_ratio]) && @subscriber_queue_size > 0
          @records.each do |r|
            ratio = r.queue.size.to_f / @subscriber_queue_size
            next if ratio < ratio_t
            alerts << {
              code:          :changefeed_queue_pressure,
              severity:      :warning,
              subscriber_id: r.id,
              value:         ratio.round(3),
              threshold:     ratio_t
            }
          end
        end

        alerts
      end
    end
  end
end
