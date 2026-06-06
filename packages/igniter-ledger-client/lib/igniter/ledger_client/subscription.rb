# frozen_string_literal: true

module Igniter
  module LedgerClient
    class Subscription
      attr_accessor :error

      def initialize(&close_proc)
        @close_proc = close_proc
        @closed = false
        @mutex = Mutex.new
      end

      def close
        close_proc = nil
        @mutex.synchronize do
          return self if @closed

          @closed = true
          close_proc = @close_proc
        end

        close_proc&.call
        self
      end

      def closed?
        @mutex.synchronize { @closed }
      end
    end
  end
end
