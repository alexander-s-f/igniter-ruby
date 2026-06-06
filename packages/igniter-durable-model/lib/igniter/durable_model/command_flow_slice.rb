# frozen_string_literal: true

module Igniter
  module DurableModel
    # App-safe temporal read model over CommandActivity history.
    class CommandFlowSlice
      attr_reader :schema_version, :kind, :owner, :filters, :since, :as_of,
                  :limit, :items, :summary, :status_counts, :command_counts,
                  :actor_counts, :subject_count, :request_count,
                  :generated_at, :execution_boundary, :store_fact_exposed,
                  :value_hash_exposed

      def initialize(owner:, filters:, since: nil, as_of: nil, limit: nil,
                     items: [], generated_at: Time.now.utc,
                     schema_version: 1, kind: :command_flow_slice,
                     execution_boundary: :app, store_fact_exposed: false,
                     value_hash_exposed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @owner = token(owner)
        @filters = normalize_hash(filters).freeze
        @since = since
        @as_of = as_of
        @limit = limit
        @items = Array(items).map { |item| normalize_hash(item).freeze }.freeze
        @status_counts = counts_for(@items, :status).freeze
        @command_counts = counts_for(@items, :command).freeze
        @actor_counts = counts_for(@items, :actor).freeze
        @subject_count = @items.map { |item| item[:subject_key] }.compact.uniq.size
        @request_count = @items.map { |item| item[:request_id] }.compact.uniq.size
        @summary = {
          total: @items.size,
          empty: @items.empty?,
          status_counts: @status_counts,
          command_counts: @command_counts,
          actor_counts: @actor_counts,
          subject_count: @subject_count,
          request_count: @request_count
        }.freeze
        @generated_at = generated_at
        @execution_boundary = token(execution_boundary)
        @store_fact_exposed = !!store_fact_exposed
        @value_hash_exposed = !!value_hash_exposed
        freeze
      end

      def empty? = items.empty?

      def size = items.size

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          owner: owner,
          filters: filters,
          since: since,
          as_of: as_of,
          limit: limit,
          items: items,
          summary: summary,
          status_counts: status_counts,
          command_counts: command_counts,
          actor_counts: actor_counts,
          subject_count: subject_count,
          request_count: request_count,
          generated_at: generated_at,
          execution_boundary: execution_boundary,
          store_fact_exposed: store_fact_exposed,
          value_hash_exposed: value_hash_exposed
        }
      end

      private

      def counts_for(entries, key)
        entries.each_with_object(Hash.new(0)) do |entry, counts|
          value = entry[key]
          counts[value] += 1 unless value.nil?
        end.to_h
      end

      def normalize_hash(value)
        return {} if value.nil?
        return value unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, entry), acc|
          acc[token(key)] = normalize_value(entry)
        end
      end

      def normalize_value(value)
        case value
        when Hash
          normalize_hash(value).freeze
        when Array
          value.map { |entry| normalize_value(entry) }.freeze
        else
          value
        end
      end

      def token(value)
        value.is_a?(String) ? value.to_sym : value
      end
    end
  end
end
