# frozen_string_literal: true

module Igniter
  module Application
    class ConfigBuilder
      def initialize
        @values = {}
      end

      def set(*path, value:)
        raise ArgumentError, "config set requires at least one key" if path.empty?

        cursor = @values
        path[0..-2].each do |segment|
          key = segment.to_sym
          cursor[key] ||= {}
          cursor = cursor.fetch(key)
        end
        cursor[path.last.to_sym] = normalize_value(value)
        self
      end

      def merge!(values)
        merge_hash!(@values, normalize_value(values))
        self
      end

      def configure
        raise ArgumentError, "configure requires a block" unless block_given?

        yield self
        self
      end

      def to_config
        Config.new(@values)
      end

      def to_h
        Config.new(@values).to_h
      end

      private

      def normalize_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), memo|
            memo[key.to_sym] = normalize_value(entry)
          end
        when Array
          value.map { |entry| normalize_value(entry) }
        else
          value
        end
      end

      def merge_hash!(target, source)
        source.each do |key, value|
          if target[key].is_a?(Hash) && value.is_a?(Hash)
            merge_hash!(target[key], value)
          else
            target[key] = value
          end
        end
      end
    end
  end
end
