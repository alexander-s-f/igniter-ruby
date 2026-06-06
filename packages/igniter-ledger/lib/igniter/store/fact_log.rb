# frozen_string_literal: true

require "monitor"

module Igniter
  module Store
    unless defined?(NATIVE) && NATIVE
      # Pure-Ruby FactLog — skipped when the Rust native extension is loaded.
      class FactLog
        include MonitorMixin

        def initialize
          super()
          @log = []
          @by_id = {}
          @by_key = Hash.new { |hash, key| hash[key] = [] }
        end

        def append(fact)
          synchronize do
            @log << fact
            @by_id[fact.id] = fact
            @by_key[[fact.store, fact.key]] << fact
          end
          fact
        end

        def replay(fact)
          synchronize do
            @log << fact
            @by_id[fact.id] = fact
            @by_key[[fact.store, fact.key]] << fact
          end
        end

        def latest_for(store:, key:, as_of: nil)
          facts = synchronize { @by_key[[store, key]].dup }
          facts = facts.select { |fact| fact.transaction_time <= as_of } if as_of
          facts.last
        end

        def facts_for(store:, key: nil, since: nil, as_of: nil)
          synchronize do
            facts = key ? @by_key[[store, key]].dup : @log.select { |fact| fact.store == store }
            facts = facts.select { |fact| fact.transaction_time >= since } if since
            facts = facts.select { |fact| fact.transaction_time <= as_of } if as_of
            facts
          end
        end

        def query_scope(store:, filters:, as_of: nil)
          synchronize do
            seen = {}
            @by_key.each do |(s, k), facts|
              next unless s == store
              candidates = as_of ? facts.select { |f| f.transaction_time <= as_of } : facts
              latest = candidates.last
              next unless latest
              seen[k] = latest if matches_filters?(latest.value, filters)
            end
            seen.values
          end
        end

        def all_facts
          synchronize { @log.dup }
        end

        def size
          synchronize { @log.size }
        end

        private

        def matches_filters?(value, filters)
          return false unless value.is_a?(Hash)
          filters.all? { |k, v| value[k] == v }
        end
      end
    end

    if defined?(NATIVE) && NATIVE
      # Patch the Rust-native FactLog to expose all_facts.
      # The native append is intercepted to track which stores have been written;
      # all_facts then collects via facts_for(store:) per known store.
      class FactLog
        alias_method :_native_append_unwrapped, :append

        def append(fact)
          @_seen_stores ||= []
          s = fact.store
          @_seen_stores << s unless @_seen_stores.include?(s)
          _native_append_unwrapped(fact)
        end

        def all_facts
          @_seen_stores ||= []
          @_seen_stores.flat_map { |s| facts_for(store: s) }.sort_by(&:transaction_time)
        end
      end
    end
  end
end
