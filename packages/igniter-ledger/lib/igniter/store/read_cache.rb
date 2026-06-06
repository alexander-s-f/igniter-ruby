# frozen_string_literal: true

require "monitor"

module Igniter
  module Store
    class ReadCache
      include MonitorMixin

      DEFAULT_LRU_CAP = 1_000

      def initialize(lru_cap: DEFAULT_LRU_CAP)
        super()
        @entries         = {}
        @consumers       = Hash.new { |hash, key| hash[key] = [] }
        @scope_consumers = Hash.new { |hash, key| hash[key] = [] }
        @lru_cap         = lru_cap
        # Tracks insertion/access order for time-travel cache entries only.
        # Current-state entries (as_of: nil) live until explicit invalidation.
        # Ruby Hash preserves insertion order; delete+reinsert = move to MRU.
        @lru_order = {}
      end

      def register_consumer(store, callable)
        synchronize { @consumers[store] << callable }
      end

      def register_scope_consumer(store, scope, callable)
        synchronize { @scope_consumers[[store, scope]] << callable }
      end

      def get(store:, key:, as_of: nil, ttl: nil)
        cache_key = [store, key, as_of]
        entry = synchronize do
          e = @entries[cache_key]
          if e && as_of
            @lru_order.delete(cache_key)
            @lru_order[cache_key] = true
          end
          e
        end
        return nil unless entry

        if ttl
          age = Process.clock_gettime(Process::CLOCK_REALTIME) - entry.fetch(:cached_at)
          return nil if age > ttl
        end

        entry.fetch(:fact)
      end

      def put(store:, key:, fact:, as_of: nil)
        cache_key = [store, key, as_of]
        synchronize do
          @entries[cache_key] = {
            fact:      fact,
            cached_at: Process.clock_gettime(Process::CLOCK_REALTIME)
          }
          if as_of
            @lru_order[cache_key] = true
            evict_lru_if_needed
          end
        end
      end

      def get_scope(store:, scope:, as_of: nil, ttl: nil)
        cache_key = [:scope, store, scope, as_of]
        entry = synchronize do
          e = @entries[cache_key]
          if e && as_of
            @lru_order.delete(cache_key)
            @lru_order[cache_key] = true
          end
          e
        end
        return nil unless entry

        if ttl
          age = Process.clock_gettime(Process::CLOCK_REALTIME) - entry.fetch(:cached_at)
          return nil if age > ttl
        end

        entry.fetch(:facts)
      end

      def put_scope(store:, scope:, facts:, as_of: nil)
        cache_key = [:scope, store, scope, as_of]
        synchronize do
          @entries[cache_key] = {
            facts:     facts,
            cached_at: Process.clock_gettime(Process::CLOCK_REALTIME)
          }
          if as_of
            @lru_order[cache_key] = true
            evict_lru_if_needed
          end
        end
      end

      # +scope_changes+ is a Hash of { scope_name => :changed | :unchanged | :unknown }
      # produced by IgniterStore#update_scope_indices.  Scope consumers are only
      # notified for scopes that are :changed or :unknown (conservative).  Scopes
      # marked :unchanged are skipped — their membership did not change and firing
      # their consumers would be a false-positive thundering herd.
      def invalidate(store:, key: nil, scope_changes: {})
        point_targets, scope_notifications = synchronize do
          affected_scopes = []
          @entries.delete_if do |cache_key, _entry|
            should_delete = if cache_key[0] == :scope && cache_key[1] == store
              affected_scopes << cache_key[2]
              true
            else
              cache_key[0] == store && (key.nil? || cache_key[1] == key)
            end
            @lru_order.delete(cache_key) if should_delete
            should_delete
          end

          notify_scopes = affected_scopes.uniq.reject do |scope|
            scope_changes[scope] == :unchanged
          end

          scope_notifs = notify_scopes.map do |scope|
            [scope, @scope_consumers[[store, scope]].dup]
          end

          [@consumers[store].dup, scope_notifs]
        end

        point_targets.each { |t| notify(t, store, key) }
        scope_notifications.each do |scope, targets|
          targets.each { |t| notify_scope(t, store, scope) }
        end
      end

      def lru_size
        synchronize { @lru_order.size }
      end

      private

      def evict_lru_if_needed
        while @lru_order.size > @lru_cap
          oldest_key, = @lru_order.first
          @lru_order.delete(oldest_key)
          @entries.delete(oldest_key)
        end
      end

      def notify(target, store, key)
        target.call(store, key)
      rescue StandardError
        nil
      end

      def notify_scope(target, store, scope)
        target.call(store, scope)
      rescue StandardError
        nil
      end
    end
  end
end
