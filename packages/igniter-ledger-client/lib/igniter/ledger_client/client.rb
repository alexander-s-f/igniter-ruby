# frozen_string_literal: true

require_relative "envelope"
require_relative "error"
require_relative "results"
require_relative "subscription"

module Igniter
  module LedgerClient
    class Client
      attr_reader :transport

      def initialize(transport:)
        @transport = transport
      end

      def register_descriptor(descriptor = nil, **fields)
        Results.wrap(:register_descriptor, dispatch(:register_descriptor, (descriptor || {}).merge(fields)))
      end

      def write(store:, key:, value:, **metadata)
        Results.wrap(:write, dispatch(:write, metadata.merge(store: store, key: key, value: value)))
      end

      def append(history:, event:, key: nil, partition_key: nil, **metadata)
        packet = metadata.merge(history: history, event: event)
        packet[:key] = key if key
        packet[:partition_key] = partition_key if partition_key
        Results.wrap(:append, dispatch(:append, packet))
      end

      def read(store:, key:, as_of: nil)
        packet = { store: store, key: key }
        packet[:as_of] = as_of if as_of
        Results.wrap(:read, dispatch(:read, packet))
      end

      def query(store:, where:, limit: nil, as_of: nil, order: nil)
        packet = { store: store, where: where }
        packet[:limit] = limit if limit
        packet[:as_of] = as_of if as_of
        packet[:order] = order if order
        Results.wrap(:query, dispatch(:query, packet))
      end

      def replay(store: nil, from: nil, to: nil, key: nil, partition_key: nil, partition_value: nil, filter: nil)
        packet = {}
        packet[:from] = from if from
        packet[:to] = to if to
        filter_packet = replay_filter(
          store: store,
          key: key,
          partition_key: partition_key,
          partition_value: partition_value,
          filter: filter
        )
        packet[:filter] = filter_packet if filter_packet
        Results.wrap(:replay, dispatch(:replay, packet))
      end

      def resolve(relation:, from:, as_of: nil)
        packet = { relation: relation, from: from }
        packet[:as_of] = as_of if as_of
        Results.wrap(:resolve, dispatch(:resolve, packet))
      end

      def causation_chain(store:, key:)
        Results.wrap(:causation_chain, dispatch(:causation_chain, { store: store, key: key }))
      end

      def lineage(store:, key:)
        Results.wrap(:lineage, dispatch(:lineage, { store: store, key: key }))
      end

      def fact_ref(fact_id)
        Results.wrap(:fact_ref, dispatch(:fact_ref, { fact_id: fact_id }))
      end

      def metadata_snapshot = dispatch(:metadata_snapshot)

      def descriptor_snapshot = dispatch(:descriptor_snapshot)

      def observability_snapshot = dispatch(:observability_snapshot)

      def compaction_activity(store: nil, kind: nil, since: nil, limit: nil)
        packet = {}
        packet[:store] = store if store
        packet[:kind] = kind if kind
        packet[:since] = since if since
        packet[:limit] = limit if limit
        dispatch(:compaction_activity, packet)
      end

      def subscribe(stores:, cursor: nil, &block)
        raise ArgumentError, "subscribe requires a block" unless block

        raise NotImplementedError, "ledger client transport does not support subscriptions" unless transport.respond_to?(:subscribe)

        transport.subscribe(stores: stores, cursor: cursor) do |event|
          block.call(Results::ChangeEventResult.new(event))
        end
      end

      def dispatch(operation, packet = {}, request_id: nil)
        request = Envelope.request(operation: operation, packet: packet, request_id: request_id)
        Envelope.result_or_raise(transport.dispatch(request))
      rescue Error
        raise
      rescue StandardError => e
        raise TransportError.new(e.message, request_id: request&.fetch(:request_id, nil))
      end

      def close
        transport.close if transport.respond_to?(:close)
      end

      private

      def replay_filter(store:, key:, partition_key:, partition_value:, filter:)
        convenience_filter = {}
        convenience_filter[:store] = store if store
        convenience_filter[:key] = key if key
        convenience_filter[:partition_key] = partition_key if partition_key
        convenience_filter[:partition_value] = partition_value if partition_value

        raise ArgumentError, "replay filter: cannot be combined with store/key/partition convenience arguments" if filter && !convenience_filter.empty?

        return filter if filter
        return nil if convenience_filter.empty?

        convenience_filter
      end
    end
  end
end
