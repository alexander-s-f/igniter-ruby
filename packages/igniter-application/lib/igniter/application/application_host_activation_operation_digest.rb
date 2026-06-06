# frozen_string_literal: true

require "digest"
require "json"

module Igniter
  module Application
    class ApplicationHostActivationOperationDigest
      def self.compute(dry_run_or_hash)
        new(dry_run_or_hash).compute
      end

      def initialize(dry_run_or_hash)
        @payload = normalize_hash(dry_run_or_hash.respond_to?(:to_h) ? dry_run_or_hash.to_h : dry_run_or_hash)
      end

      def compute
        Digest::SHA256.hexdigest(JSON.generate(normalized_payload))
      end

      private

      attr_reader :payload

      def normalized_payload
        {
          would_apply: normalize_operations(value(payload, :would_apply)),
          skipped: normalize_operations(value(payload, :skipped))
        }
      end

      def normalize_operations(operations)
        Array(operations).map { |entry| normalize_hash(entry) }
                         .sort_by { |entry| [value(entry, :type).to_s, value(entry, :destination).to_s] }
                         .map { |entry| normalize_value(entry) }
      end

      def normalize_value(item)
        case item
        when Hash
          item.each_with_object({}) do |(key, value), result|
            next if key.to_s.end_with?("_at")

            result[key.to_s] = normalize_value(value)
          end.sort.to_h
        when Array
          item.map { |entry| normalize_value(entry) }
        when Symbol
          item.to_s
        else
          item
        end
      end

      def normalize_hash(value)
        source = value.respond_to?(:to_h) ? value.to_h : {}
        source.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end

      def value(hash, key)
        return nil unless hash.respond_to?(:key?)
        return hash[key] if hash.key?(key)

        hash[key.to_s]
      end
    end
  end
end
