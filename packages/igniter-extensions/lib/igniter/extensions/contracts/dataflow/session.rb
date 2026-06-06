# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Dataflow
        class Session
          attr_reader :environment, :compiled_graph, :source, :key_name, :window, :context, :last_result

          def initialize(environment:, compiled_graph:, source:, key:, window: nil, context: [],
                         aggregate_operators: {})
            @environment = environment
            @compiled_graph = compiled_graph
            @source = source.to_sym
            @key_name = key.to_sym
            @window = window
            @context = Array(context).map(&:to_sym).freeze
            @aggregate_states = aggregate_operators.transform_values { |operator| AggregateState.new(operator) }
            @item_sessions = {}
            @snapshots = {}
            @cached_items = {}
            @last_inputs = nil
            @last_result = nil
          end

          def run(inputs:)
            normalized_inputs = Igniter::Contracts::NamedValues.new(inputs)
            items = filtered_items(normalized_inputs.fetch(source))
            diff = compute_diff(items)
            processed_items = build_processed_items(items, normalized_inputs, diff)
            delete_removed_sessions(diff.removed)

            collection_result = CollectionResult.new(items: processed_items, diff: diff)
            update_aggregate_states(collection_result)

            @snapshots = snapshot_items(items)
            @cached_items = processed_items.dup
            @last_inputs = normalized_inputs
            @last_result = Result.new(
              processed: collection_result,
              aggregates: @aggregate_states.transform_values(&:value),
              inputs: normalized_inputs
            )
          end

          def feed_diff(add: [], remove: [], update: [], inputs: {})
            current_inputs = @last_inputs.to_h
            current_items = Array(current_inputs.fetch(source, []))
            merged_items = apply_diff(current_items, add: add, remove: remove, update: update)

            run(inputs: current_inputs.merge(inputs).merge(source => merged_items))
          end

          def collection_diff
            @last_result&.diff
          end

          private

          def filtered_items(items)
            normalized_items = Array(items).map { |item| normalize_item(item) }
            WindowFilter.new(window).apply(normalized_items)
          end

          def normalize_item(item)
            raise TypeError, "dataflow items must be Hash-like" unless item.is_a?(Hash)

            item.transform_keys(&:to_sym)
          end

          def build_processed_items(items, normalized_inputs, diff)
            items.each_with_object({}) do |item, memo|
              key = extract_key(item)
              memo[key] =
                if diff.unchanged.include?(key)
                  @cached_items.fetch(key)
                else
                  resolve_item(item, normalized_inputs)
                end
            end
          end

          def resolve_item(item, normalized_inputs)
            key = extract_key(item)
            session = @item_sessions[key] ||= Igniter::Extensions::Contracts::IncrementalPack.session(
              environment,
              compiled_graph: compiled_graph
            )
            item_inputs = context.each_with_object({}) do |name, memo|
              memo[name] = normalized_inputs.fetch(name)
            end.merge(item)
            incremental_result = session.run(inputs: item_inputs)

            ItemResult.new(
              key: key,
              inputs: item_inputs,
              execution_result: incremental_result.execution_result,
              incremental_result: incremental_result
            )
          end

          def compute_diff(items)
            current_keys = items.to_h { |item| [extract_key(item), item] }
            added = []
            changed = []
            unchanged = []

            items.each do |item|
              key = extract_key(item)
              fingerprint = fingerprint(item)

              if !@snapshots.key?(key)
                added << key
              elsif @snapshots.fetch(key) != fingerprint
                changed << key
              else
                unchanged << key
              end
            end

            removed = @snapshots.keys.reject { |key| current_keys.key?(key) }

            Diff.new(added: added, removed: removed, changed: changed, unchanged: unchanged)
          end

          def snapshot_items(items)
            items.to_h { |item| [extract_key(item), fingerprint(item)] }
          end

          def fingerprint(item)
            item.sort_by { |name, _| name.to_s }
                .map { |name, value| "#{name}:#{value.inspect}" }
                .hash
                .to_s
          end

          def extract_key(item)
            item.fetch(key_name)
          end

          def delete_removed_sessions(removed_keys)
            removed_keys.each do |key|
              @item_sessions.delete(key)
            end
          end

          def update_aggregate_states(collection_result)
            @aggregate_states.each_value do |state|
              state.apply_diff!(collection_result.diff, collection_result)
            end
          end

          def apply_diff(items, add:, remove:, update:)
            remove_keys = Array(remove).map do |entry|
              entry.is_a?(Hash) ? normalize_item(entry).fetch(key_name) : entry
            end
            result = items.map { |item| normalize_item(item) }
                          .reject { |item| remove_keys.include?(item.fetch(key_name)) }

            Array(update).each do |entry|
              updated = normalize_item(entry)
              key = updated.fetch(key_name)
              index = result.index { |item| item.fetch(key_name) == key }
              index ? result[index] = updated : result << updated
            end

            result.concat(Array(add).map { |entry| normalize_item(entry) })
          end
        end
      end
    end
  end
end
