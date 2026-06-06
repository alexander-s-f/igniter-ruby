# frozen_string_literal: true

# Try to load the compiled Rust extension.
# Falls back silently to pure-Ruby implementations if not compiled.
begin
  # The compiled bundle lives in the same directory as this file.
  $LOAD_PATH.unshift(__dir__) unless $LOAD_PATH.include?(__dir__)
  require "igniter_store_native"

  # ── Ruby wrappers on top of Rust-defined Fact ─────────────────────────────
  # Translates keyword args to the positional _native_build method (8-arg form).
  class Igniter::Store::Fact
    def self.build(store:, key:, value:, causation: nil, valid_time: nil, term: nil,
                   schema_version: 1, producer: nil, derivation: nil)
      # term: is a deprecated alias for valid_time — accepted for compat.
      vt = valid_time.nil? ? (term ? term.to_f : nil) : valid_time.to_f
      _native_build(
        store.to_s,
        key.to_s,
        value,
        causation,
        vt,
        schema_version.to_i,
        producer,
        derivation
      )
    end

    alias_method :_native_value, :value
    alias_method :_native_producer, :producer
    alias_method :_native_derivation, :derivation

    def value = self.class.deep_freeze_native_value(_native_value)

    def producer = self.class.deep_freeze_native_value(_native_producer)

    def derivation = self.class.deep_freeze_native_value(_native_derivation)

    def self.deep_freeze_native_value(value)
      case value
      when Hash
        value.transform_values { |entry| deep_freeze_native_value(entry) }.freeze
      when Array
        value.map { |entry| deep_freeze_native_value(entry) }.freeze
      else
        value.frozen? ? value : value.dup.freeze
      end
    end
  end

  # ── Ruby wrappers on top of Rust-defined FactLog ──────────────────────────
  # Translates keyword args to positional native methods.
  class Igniter::Store::FactLog
    def initialize(backend: nil)
      # backend is handled by IgniterStore, not stored here
    end

    def append(fact)
      _native_append(fact)
      fact
    end

    def latest_for(store:, key:, as_of: nil)
      latest_for_native(store.to_s, key.to_s, as_of&.to_f)
    end

    def facts_for(store:, key: nil, since: nil, as_of: nil)
      facts_for_native(store.to_s, key&.to_s, since&.to_f, as_of&.to_f)
    end

    def query_scope(store:, filters:, as_of: nil)
      query_scope_native(store.to_s, filters, as_of&.to_f)
    end
  end

  Igniter::Store.send(:remove_const, :NATIVE) if Igniter::Store.const_defined?(:NATIVE)
  Igniter::Store::NATIVE = true
rescue LoadError
  # NATIVE already set to false by store.rb
end
