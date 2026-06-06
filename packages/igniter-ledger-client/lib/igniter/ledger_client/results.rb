# frozen_string_literal: true

module Igniter
  module LedgerClient
    module Results
      module HashAccess
        def [](key)
          to_h[key.to_sym]
        end
      end

      class ReceiptResult
        include HashAccess

        FIELDS = %i[
          schema_version
          kind
          status
          name
          store
          key
          fact_id
          value_hash
          warnings
          errors
          derived
        ].freeze

        attr_reader(*FIELDS)

        def initialize(raw = {})
          data = self.class.normalize(raw)
          @schema_version = data[:schema_version]
          @kind = token(data[:kind])
          @status = token(data[:status])
          @name = token(data[:name])
          @store = token(data[:store])
          @key = data[:key]
          @fact_id = data[:fact_id]
          @value_hash = data[:value_hash]
          @warnings = Array(data[:warnings]).freeze
          @errors = Array(data[:errors]).freeze
          @derived = Array(data[:derived]).freeze
          freeze
        end

        def accepted? = status == :accepted

        def rejected? = status == :rejected

        def deduplicated? = status == :deduplicated

        def to_h
          {
            schema_version: schema_version,
            kind: kind,
            status: status,
            name: name,
            store: store,
            key: key,
            fact_id: fact_id,
            value_hash: value_hash,
            warnings: warnings,
            errors: errors,
            derived: derived
          }.compact
        end

        def self.normalize(raw)
          hash = if raw.respond_to?(:to_h)
                   raw.to_h
                 else
                   FIELDS.each_with_object({}) do |field, acc|
                     acc[field] = raw.public_send(field) if raw.respond_to?(field)
                   end
                 end

          hash.to_h.transform_keys(&:to_sym)
        end

        private

        def token(value)
          value.is_a?(String) ? value.to_sym : value
        end
      end

      class WriteResult < ReceiptResult
      end

      class AppendResult < ReceiptResult
      end

      class ReadResult
        include HashAccess

        attr_reader :value

        def initialize(raw = {})
          data = normalize(raw)
          @value = data[:value]
          @found = data.key?(:found) ? boolean(data[:found]) : !value.nil?
          freeze
        end

        def found? = @found

        def to_h
          { value: value, found: found? }
        end

        private

        def normalize(raw)
          hash = raw.respond_to?(:to_h) ? raw.to_h : {}
          hash.each_with_object({}) { |(key, value), acc| acc[key.to_sym] = value }
        end

        def boolean(value)
          value ? true : false
        end
      end

      class QueryResult
        include HashAccess

        attr_reader :items, :results, :count

        def initialize(raw = {})
          data = normalize(raw)
          @items = normalize_items(data[:items]).freeze
          @results = Array(data[:results] || items.map { |item| item[:value] }).freeze
          @count = data.key?(:count) ? data[:count].to_i : [items.size, results.size].max
          freeze
        end

        def to_h
          { items: items, results: results, count: count }
        end

        private

        def normalize(raw)
          hash = raw.respond_to?(:to_h) ? raw.to_h : {}
          hash.each_with_object({}) { |(key, value), acc| acc[key.to_sym] = value }
        end

        def normalize_items(raw_items)
          Array(raw_items).map do |item|
            data = item.to_h.transform_keys(&:to_sym)
            { key: data[:key], value: normalize_value(data[:value] || {}) }
          end
        end

        def normalize_value(value)
          return value unless value.is_a?(Hash)

          value.each_with_object({}) { |(key, entry), acc| acc[key.to_sym] = entry }
        end
      end

      class ResolveResult
        include HashAccess

        attr_reader :items, :results, :count

        def initialize(raw = {})
          data = normalize(raw)
          @items = normalize_items(data[:items]).freeze
          @results = Array(data[:results] || items.map { |item| item[:value] }).freeze
          @count = data.key?(:count) ? data[:count].to_i : [items.size, results.size].max
          freeze
        end

        def to_h
          { items: items, results: results, count: count }
        end

        private

        def normalize(raw)
          return { results: raw } if raw.is_a?(Array)

          hash = raw.respond_to?(:to_h) ? raw.to_h : {}
          hash.each_with_object({}) { |(key, value), acc| acc[key.to_sym] = value }
        end

        def normalize_items(raw_items)
          Array(raw_items).map do |item|
            data = item.to_h.transform_keys(&:to_sym)
            { key: data[:key], value: normalize_value(data[:value] || {}) }
          end
        end

        def normalize_value(value)
          return value unless value.is_a?(Hash)

          value.each_with_object({}) { |(key, entry), acc| acc[key.to_sym] = entry }
        end
      end

      class ReplayResult
        include HashAccess

        attr_reader :facts, :count

        def initialize(raw = {})
          data = normalize(raw)
          @facts = Array(data[:facts]).freeze
          @count = data.key?(:count) ? data[:count].to_i : facts.size
          freeze
        end

        def to_h
          { facts: facts, count: count }
        end

        private

        def normalize(raw)
          hash = raw.respond_to?(:to_h) ? raw.to_h : {}
          hash.each_with_object({}) { |(key, value), acc| acc[key.to_sym] = value }
        end
      end

      class CausationChainResult
        include HashAccess

        attr_reader :chain, :count

        def initialize(raw = {})
          data = normalize(raw)
          @chain = Array(data[:chain]).map { |entry| normalize_hash(entry) }.freeze
          @count = data.key?(:count) ? data[:count].to_i : chain.size
          freeze
        end

        def to_h
          { chain: chain, count: count }
        end

        private

        def normalize(raw)
          return { chain: raw } if raw.is_a?(Array)

          normalize_hash(raw)
        end

        def normalize_hash(raw)
          raw.respond_to?(:to_h) ? raw.to_h.transform_keys(&:to_sym) : {}
        end
      end

      class LineageResult
        include HashAccess

        attr_reader :subject, :chain, :depth, :derived_by, :proof_hash

        def initialize(raw = {})
          data = normalize_hash(raw)
          @subject = normalize_hash(data[:subject]).freeze
          @chain = Array(data[:chain]).map { |entry| normalize_hash(entry) }.freeze
          @depth = data.key?(:depth) ? data[:depth].to_i : chain.size
          @derived_by = Array(data[:derived_by]).map { |entry| normalize_hash(entry) }.freeze
          @proof_hash = data[:proof_hash]
          freeze
        end

        def to_h
          {
            subject: subject,
            chain: chain,
            depth: depth,
            derived_by: derived_by,
            proof_hash: proof_hash
          }
        end

        private

        def normalize_hash(raw)
          raw.respond_to?(:to_h) ? raw.to_h.transform_keys(&:to_sym) : {}
        end
      end

      class FactRefResult
        include HashAccess

        attr_reader :ref

        def initialize(raw = {})
          data = normalize_hash(raw)
          @ref = data[:ref] ? normalize_hash(data[:ref]).freeze : nil
          @found = if data.key?(:found)
                     data[:found] ? true : false
                   else
                     !ref.nil?
                   end
          freeze
        end

        def found? = @found

        def to_h
          { found: found?, ref: ref }
        end

        private

        def normalize_hash(raw)
          raw.respond_to?(:to_h) ? raw.to_h.transform_keys(&:to_sym) : {}
        end
      end

      class ChangeEventResult
        include HashAccess

        attr_reader :sequence, :store, :key, :fact_id, :value_hash, :cursor, :raw

        def initialize(raw = {})
          @raw = raw
          data = normalize(raw)
          @cursor = normalize_cursor(data[:cursor])
          @sequence = (data[:sequence] || cursor[:sequence])&.to_i
          @store = token(data[:store])
          @key = data[:key]
          @fact_id = data[:fact_id]
          @value_hash = data[:value_hash] || fact_value_hash(raw)
          freeze
        end

        def to_h
          {
            sequence: sequence,
            store: store,
            key: key,
            fact_id: fact_id,
            value_hash: value_hash,
            cursor: cursor,
            raw: raw
          }.compact
        end

        private

        def normalize(raw)
          hash = if raw.respond_to?(:to_h)
                   raw.to_h
                 else
                   %i[sequence store key fact_id value_hash cursor].each_with_object({}) do |field, acc|
                     acc[field] = raw.public_send(field) if raw.respond_to?(field)
                   end
                 end

          hash.to_h.transform_keys(&:to_sym)
        end

        def normalize_cursor(cursor)
          return {} unless cursor

          cursor.to_h.transform_keys(&:to_sym).freeze
        end

        def fact_value_hash(raw)
          return raw.fact.value_hash if raw.respond_to?(:fact) && raw.fact.respond_to?(:value_hash)

          nil
        end

        def token(value)
          value.is_a?(String) ? value.to_sym : value
        end
      end

      module_function

      def wrap(operation, raw)
        case operation.to_sym
        when :register_descriptor
          ReceiptResult.new(raw)
        when :write
          WriteResult.new(raw)
        when :append
          AppendResult.new(raw)
        when :read
          ReadResult.new(raw)
        when :query
          QueryResult.new(raw)
        when :resolve
          ResolveResult.new(raw)
        when :replay
          ReplayResult.new(raw)
        when :causation_chain
          CausationChainResult.new(raw)
        when :lineage
          LineageResult.new(raw)
        when :fact_ref
          FactRefResult.new(raw)
        else
          raw
        end
      end
    end
  end
end
