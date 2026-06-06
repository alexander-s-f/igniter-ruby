# frozen_string_literal: true

require "securerandom"
require "json"

module Igniter
  module Store
    # Routing layer of the reactive push architecture.
    #
    # Tracks SubscriptionRecord objects and fans out facts to their handlers.
    # Knows nothing about sockets, frames, or wire encoding — those are the
    # adapter's responsibility.  The handler is any callable: ->(fact) { ... }
    #
    # TCP push adapter example (created in handle_subscription_mode):
    #   write_mutex = Mutex.new
    #   adapter = ->(fact) {
    #     frame = encode_frame(JSON.generate({ event: "fact_written", fact: fact.to_h }))
    #     write_mutex.synchronize { socket.write(frame) }
    #   }
    #   record = registry.subscribe(stores: [:tasks], &adapter)
    #   # ... later:
    #   registry.unsubscribe(record)
    #
    # Future adapters (WebhookAdapter, SSEAdapter, QueueAdapter) follow the same
    # ->(fact) { ... } contract and plug in without modifying this class.
    class SubscriptionRegistry
      SubscriptionRecord = Struct.new(:id, :stores, :handler, keyword_init: true)

      def initialize
        @records = []
        @mutex   = Mutex.new
      end

      # Register a handler callable for one or more store names.
      # Returns the SubscriptionRecord — pass it to #unsubscribe to remove.
      def subscribe(stores:, &handler)
        record = SubscriptionRecord.new(
          id:      SecureRandom.hex(8),
          stores:  Array(stores).map(&:to_s),
          handler: handler
        )
        @mutex.synchronize { @records << record }
        record
      end

      # Remove a subscription. Identity-based (object equality), idempotent.
      def unsubscribe(record)
        return unless record
        @mutex.synchronize { @records.reject! { |r| r.equal?(record) } }
      end

      # Fan out a fact to all handlers subscribed to fact.store.
      # Called from dispatch("write_fact") after the fact is persisted.
      # Handlers that raise are treated as dead and removed.
      def fan_out(fact)
        store_s  = fact.store.to_s
        matching = @mutex.synchronize { @records.select { |r| r.stores.include?(store_s) }.dup }
        dead     = []
        matching.each do |record|
          record.handler.call(fact)
        rescue StandardError
          dead << record
        end
        dead.each { |r| unsubscribe(r) } unless dead.empty?
      end

      # Number of active subscriptions for a given store name.
      def subscriber_count(store)
        @mutex.synchronize { @records.count { |r| r.stores.include?(store.to_s) } }
      end
    end
  end
end
