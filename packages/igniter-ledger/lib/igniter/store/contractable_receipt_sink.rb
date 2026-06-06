# frozen_string_literal: true

module Igniter
  module Store
    # Durable sink for contractable observation/event receipts emitted by
    # igniter-embed's contractable runner.
    #
    # Implements the record_observation / record_event store adapter protocol
    # so it can be passed directly as the `store:` option to any contractable.
    #
    # Idempotency policy:
    #   record_observation — keyed by observation_id; same id overwrites the
    #     current fact and creates a causation chain entry. Safe to retry.
    #   record_event — append-only history; retries produce duplicate entries.
    #     Callers should deduplicate at the source if needed.
    class ContractableReceiptSink
      REQUIRED_OBSERVATION_FIELDS = %i[observation_id receipt_kind].freeze
      REQUIRED_EVENT_FIELDS = %i[event_id receipt_kind observation_id].freeze

      attr_reader :store, :client, :observations_store, :events_store, :producer

      def initialize(
        store: nil,
        client: nil,
        observations_store: :contractable_observations,
        events_store: :contractable_events,
        producer: { type: :embed, name: :contractable_receipt_sink }
      )
        raise ArgumentError, "ContractableReceiptSink requires store: or client:" unless store || client

        @store = store
        @client = client
        @observations_store = observations_store.to_sym
        @events_store = events_store.to_sym
        @producer = producer
        register_descriptors
      end

      def record_observation(receipt)
        validate_receipt!(receipt, REQUIRED_OBSERVATION_FIELDS, :contractable_observation)
        target.write(
          store: observations_store,
          key: receipt[:observation_id].to_s,
          value: receipt,
          producer: producer
        )
      end

      def record_event(receipt)
        validate_receipt!(receipt, REQUIRED_EVENT_FIELDS, :contractable_event)
        target.append(
          history: events_store,
          event: receipt,
          partition_key: :observation_id,
          producer: producer
        )
      end

      def observation(observation_id)
        normalize_read_result(target.read(store: observations_store, key: observation_id.to_s))
      end

      def events_for(observation_id)
        history_partition_values(
          store: events_store,
          partition_key: :observation_id,
          partition_value: observation_id.to_s
        )
      end

      def observations(status: nil, limit: nil)
        all_facts = history_facts(store: observations_store)
        by_key = {}
        all_facts.each { |f| by_key[fact_key(f)] = f }
        results = by_key.values.sort_by { |f| fact_transaction_time(f) }.map { |f| fact_value(f) }
        results = results.select { |r| r[:status] == status } if status
        limit ? results.take(limit) : results
      end

      def error_events(limit: nil)
        results = history_facts(store: events_store).map { |f| fact_value(f) }.select { |r| r[:severity] == :error }
        limit ? results.take(limit) : results
      end

      private

      def target
        client || store
      end

      def validate_receipt!(receipt, required_fields, expected_kind)
        missing = required_fields.select { |f| receipt[f].nil? }
        raise ArgumentError, "contractable receipt missing required fields: #{missing.join(", ")}" if missing.any?

        actual_kind = receipt[:receipt_kind]
        return if actual_kind == expected_kind

        raise ArgumentError, "expected receipt_kind #{expected_kind.inspect}, got #{actual_kind.inspect}"
      end

      def register_descriptors
        target.register_descriptor(
          kind: :store,
          name: observations_store,
          key: :observation_id,
          fields: %i[observation_id name role stage status sampled async started_at finished_at duration_ms redaction],
          producer: { system: :igniter_embed }
        )
        target.register_descriptor(
          kind: :history,
          name: events_store,
          key: :event_id,
          partition_key: :observation_id,
          fields: %i[event_id observation_id event severity summary occurred_at]
        )
      end

      def normalize_read_result(result)
        return result.value if result.respond_to?(:value) && result.respond_to?(:found?)

        if result.is_a?(Hash) && result.key?(:value)
          result[:value]
        else
          result
        end
      end

      def history_partition_values(store:, partition_key:, partition_value:)
        if target.respond_to?(:history_partition)
          return target.history_partition(
            store: store,
            partition_key: partition_key,
            partition_value: partition_value
          ).map(&:value)
        end

        history_facts(store: store)
          .map { |f| fact_value(f) }
          .select { |value| value[partition_key] == partition_value }
      end

      def history_facts(store:)
        return target.history(store: store) if target.respond_to?(:history)

        replay_result = target.replay(store: store)
        return replay_result.facts if replay_result.respond_to?(:facts)

        if replay_result.is_a?(Hash) && replay_result.key?(:facts)
          replay_result[:facts]
        else
          Array(replay_result)
        end
      end

      def fact_key(fact)
        fact.is_a?(Hash) ? fact[:key] : fact.key
      end

      def fact_value(fact)
        fact.is_a?(Hash) ? fact[:value] : fact.value
      end

      def fact_transaction_time(fact)
        if fact.is_a?(Hash)
          fact[:transaction_time] || fact[:timestamp] || 0
        else
          fact.transaction_time
        end
      end
    end
  end
end
