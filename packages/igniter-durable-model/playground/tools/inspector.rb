# frozen_string_literal: true

module Playground
  module Tools
    # Introspects the internal state of the underlying IgniterStore.
    # Useful for understanding what the store "knows" at runtime — scope indices,
    # partition indices, cache occupancy — without modifying its behaviour.
    #
    # Usage:
    #   store     = Playground.store
    #   inspector = Playground::Tools::Inspector.new(store)
    #   inspector.print_stats
    #   inspector.scope_index        # => { [:tasks, :open] => 3, ... }
    #   inspector.partition_index    # => { [:tracker_entries, :tracker_id] => {"sleep"=>4} }
    class Inspector
      def initialize(durable_model_store)
        @inner = durable_model_store.instance_variable_get(:@inner)
      end

      # Returns a flat hash of key metrics.
      def stats
        {
          fact_count:        @inner.fact_count,
          lru_cache_size:    cache.lru_size,
          scope_indices:     scope_index_summary,
          partition_indices: partition_index_summary,
          native:            Igniter::Store::NATIVE
        }
      end

      # Scope index: { [store, scope] => Set<key> } → summarised as entry count.
      def scope_index
        raw = @inner.instance_variable_get(:@scope_index) || {}
        raw.transform_values(&:size)
      end

      # Partition index: { [store, pk] => { pv => [fact,...] } } → entry counts.
      def partition_index
        raw = @inner.instance_variable_get(:@partition_index) || {}
        raw.transform_values { |groups| groups.transform_values(&:size) }
      end

      # Schema graph: registered paths per store.
      def registered_paths
        graph = @inner.schema_graph
        graph.instance_variable_get(:@paths).to_h do |store, paths|
          [store, paths.map { |p| { scope: p.scope, filters: p.filters, consumers: p.consumers.size } }]
        end
      end

      def print_stats(out: $stdout)
        s = stats
        w = 22
        out.puts "\n#{"═" * 50}"
        out.puts "  IgniterStore Inspector"
        out.puts "#{"═" * 50}"
        out.puts "  #{"Facts in log:".ljust(w)} #{s[:fact_count]}"
        out.puts "  #{"LRU cache size:".ljust(w)} #{s[:lru_cache_size]}"
        out.puts "  #{"Native backend:".ljust(w)} #{s[:native]}"

        unless s[:scope_indices].empty?
          out.puts "\n  Scope indices (warm = lazily built on first query):"
          s[:scope_indices].each do |(store, scope), count|
            out.puts "    [#{store}, :#{scope}]  #{count} keys"
          end
        end

        unless s[:partition_indices].empty?
          out.puts "\n  Partition indices:"
          s[:partition_indices].each do |(store, pk), groups|
            out.puts "    [#{store}, :#{pk}]"
            groups.each { |pv, cnt| out.puts "      #{pv.inspect}  →  #{cnt} events" }
          end
        end

        registered = registered_paths
        unless registered.empty?
          out.puts "\n  Registered paths:"
          registered.each do |store, paths|
            paths.each do |p|
              scope    = p[:scope] ? ":#{p[:scope]}" : "(point)"
              filters  = p[:filters]&.inspect || "{}"
              consumers = p[:consumers]
              out.puts "    #{store}  #{scope.ljust(16)}  filters=#{filters}  consumers=#{consumers}"
            end
          end
        end

        out.puts "#{"═" * 50}\n"
      end

      private

      def cache
        @inner.instance_variable_get(:@cache)
      end

      def scope_index_summary
        scope_index
      end

      def partition_index_summary
        partition_index
      end
    end
  end
end
