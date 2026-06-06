# frozen_string_literal: true

require_relative "../subscription"

module Igniter
  module LedgerClient
    module Transports
      class ObjectDispatch
        def initialize(target)
          @target = target
        end

        def dispatch(envelope)
          if @target.respond_to?(:dispatch)
            @target.dispatch(envelope)
          elsif @target.respond_to?(:wire)
            @target.wire.dispatch(envelope)
          elsif @target.respond_to?(:protocol) && @target.protocol.respond_to?(:wire)
            @target.protocol.wire.dispatch(envelope)
          else
            raise ArgumentError, "object does not expose dispatch(envelope), wire.dispatch(envelope), or protocol.wire.dispatch(envelope)"
          end
        end

        def subscribe(stores:, cursor: nil, &block)
          raise ArgumentError, "subscribe requires a block" unless block

          feed = changefeed_source
          raise NotImplementedError, "object dispatch target does not expose changefeed.subscribe" unless feed.respond_to?(:subscribe)

          replay(feed, stores: stores, cursor: cursor, handler: block) if cursor
          handle = feed.subscribe(stores: stores) { |event| block.call(event) }
          Subscription.new { handle.close }
        end

        def close
          @target.close if @target.respond_to?(:close)
        end

        private

        def changefeed_source
          @target.changefeed if @target.respond_to?(:changefeed)
        end

        def replay(feed, stores:, cursor:, handler:)
          return unless feed.respond_to?(:replay)

          store_filter = Array(stores).empty? ? nil : stores
          result = feed.replay(cursor: normalize_cursor(cursor), stores: store_filter)
          raise TransportError, "changefeed cursor is too old" if result[:status].to_sym == :cursor_too_old

          Array(result[:events]).each { |event| handler.call(event) }
        end

        def normalize_cursor(cursor)
          return cursor if cursor.is_a?(Hash)

          { sequence: cursor.to_i }
        end
      end
    end
  end
end
