# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

module Igniter
  module Store
    unless defined?(NATIVE) && NATIVE
      # Pure-Ruby Fact Struct — skipped when the Rust native extension is loaded.
      # The native extension provides its own Fact class with :build and reader methods.
      Fact = Struct.new(
        :id,
        :store,
        :key,
        :value,
        :value_hash,
        :causation,
        :transaction_time,
        :valid_time,
        :schema_version,
        :producer,
        :derivation,
        keyword_init: true
      ) do
        # Canonical build entry point.
        # valid_time: domain time (writer-supplied, nullable Float).
        # term: backward-compat alias for valid_time — accepted but deprecated.
        def self.build(store:, key:, value:, causation: nil, valid_time: nil, term: nil,
                       schema_version: 1, producer: nil, derivation: nil)
          vt = valid_time.nil? ? (term ? term.to_f : nil) : valid_time.to_f
          serialized = JSON.generate(stable_sort(value))
          new(
            id:               SecureRandom.uuid,
            store:            store,
            key:              key,
            value:            deep_freeze(value),
            value_hash:       Digest::SHA256.hexdigest(serialized),
            causation:        causation,
            transaction_time: Process.clock_gettime(Process::CLOCK_REALTIME),
            valid_time:       vt,
            schema_version:   schema_version,
            producer:         producer ? deep_freeze(producer) : nil,
            derivation:       derivation ? deep_freeze(derivation) : nil
          ).freeze
        end

        private_class_method def self.stable_sort(value)
          case value
          when Hash
            value.sort_by { |key, _entry| key.to_s }.to_h do |key, entry|
              [key.to_s, stable_sort(entry)]
            end
          when Array
            value.map { |entry| stable_sort(entry) }
          else
            value
          end
        end

        private_class_method def self.deep_freeze(value)
          case value
          when Hash
            value.transform_values { |entry| deep_freeze(entry) }.freeze
          when Array
            value.map { |entry| deep_freeze(entry) }.freeze
          else
            value.frozen? ? value : value.dup.freeze
          end
        end

        # Backward-compat: callers that read fact.timestamp still work.
        alias_method :timestamp, :transaction_time
        # Backward-compat: callers that read fact.term still work.
        alias_method :term, :valid_time
      end
    end

    # Reopen Fact (Ruby Struct or native class) and add from_h + normalizations.
    class Fact
      if defined?(Igniter::Store::NATIVE) && Igniter::Store::NATIVE
        # Native extension stores `store` as a Rust String; normalize to Symbol
        # to match the Ruby Struct fallback behaviour.
        alias_method :_native_store_str, :store
        def store = _native_store_str.to_sym
      end

      # Reconstruct a Fact from a wire-deserialized hash.
      # Accepts both old field names (timestamp, term) and new names
      # (transaction_time, valid_time) for smooth transition.
      #
      # In native mode: Fact.new is unavailable (no Ruby allocator), so we call
      # Fact.build which recomputes id and transaction_time. This is a known
      # Phase 2 gap for time-travel fidelity over the network.
      def self.from_h(h)
        h = h.transform_keys(&:to_sym)
        h[:store]    = h.fetch(:store).to_sym
        # Accept both old (timestamp) and new (transaction_time) key names.
        h[:transaction_time] = (h[:transaction_time] || h[:timestamp])&.to_f || 0.0
        h[:valid_time]       = (h[:valid_time] || h[:term])&.to_f

        if defined?(Igniter::Store::NATIVE) && Igniter::Store::NATIVE
          build(
            store:        h[:store],
            key:          h[:key],
            value:        h[:value],
            causation:    h[:causation],
            valid_time:   h[:valid_time],
            schema_version: h.fetch(:schema_version, 1),
            producer:     h[:producer],
            derivation:   h[:derivation]
          )
        else
          new(**h.slice(:id, :store, :key, :value, :value_hash, :causation,
                        :transaction_time, :valid_time, :schema_version,
                        :producer, :derivation)).freeze
        end
      end
    end
  end
end
