# frozen_string_literal: true

module Igniter
  module Application
    class Config
      def initialize(values = {})
        @values = deep_freeze_hash(symbolize_hash(values))
        freeze
      end

      def fetch(*path, default: :__igniter_missing__)
        raise ArgumentError, "config fetch requires at least one key" if path.empty?

        current = @values
        path.each do |segment|
          key = segment.to_sym
          if current.is_a?(Hash) && current.key?(key)
            current = current.fetch(key)
          elsif default == :__igniter_missing__
            raise KeyError, "config key path #{path.inspect} is not set"
          else
            return default
          end
        end

        current
      end

      def section(name)
        value = @values.fetch(name.to_sym, {})
        return self.class.new(value) if value.is_a?(Hash)

        raise KeyError, "config section #{name.inspect} is not a hash"
      end

      def key?(name)
        @values.key?(name.to_sym)
      end

      def to_h
        deep_dup(@values)
      end

      private

      def symbolize_hash(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), memo|
            memo[key.to_sym] = symbolize_hash(entry)
          end
        when Array
          value.map { |entry| symbolize_hash(entry) }
        else
          value
        end
      end

      def deep_freeze_hash(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), memo|
            memo[key] = deep_freeze_hash(entry)
          end.freeze
        when Array
          value.map { |entry| deep_freeze_hash(entry) }.freeze
        else
          value.freeze
        end
      end

      def deep_dup(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), memo|
            memo[key] = deep_dup(entry)
          end
        when Array
          value.map { |entry| deep_dup(entry) }
        else
          value
        end
      end
    end
  end
end
