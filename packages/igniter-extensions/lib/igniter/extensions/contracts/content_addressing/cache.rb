# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module ContentAddressing
        class Cache
          def initialize
            @store = {}
            @hits = 0
            @misses = 0
            @mutex = Mutex.new
          end

          def fetch(key)
            @mutex.synchronize do
              entry = @store[key.hex]
              if entry.nil?
                @misses += 1
                nil
              else
                @hits += 1
                entry
              end
            end
          end

          def store(key, value)
            @mutex.synchronize do
              @store[key.hex] = value
            end
          end

          def clear
            @mutex.synchronize do
              @store.clear
              @hits = 0
              @misses = 0
            end
          end

          def size
            @mutex.synchronize { @store.size }
          end

          def stats
            @mutex.synchronize do
              {
                size: @store.size,
                hits: @hits,
                misses: @misses
              }
            end
          end
        end
      end
    end
  end
end
