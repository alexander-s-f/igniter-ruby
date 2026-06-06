# frozen_string_literal: true

module Igniter
  module Lang
    class MetadataManifest
      SEMANTICS = {
        report_only: true,
        runtime_enforced: false
      }.freeze

      attr_reader :descriptors, :return_types, :budgets

      def self.from_operations(operations)
        new(
          descriptors: extract_descriptors(operations),
          return_types: extract_return_types(operations),
          budgets: extract_budgets(operations)
        )
      end

      def initialize(descriptors: [], return_types: [], budgets: [])
        @descriptors = freeze_entries(descriptors)
        @return_types = freeze_entries(return_types)
        @budgets = freeze_entries(budgets)
        freeze
      end

      def report_only?
        true
      end

      def runtime_enforced?
        false
      end

      def to_h
        {
          descriptors: descriptors,
          return_types: return_types,
          budgets: budgets,
          stores: [],
          invariants: [],
          semantics: SEMANTICS
        }
      end

      class << self
        private

        def extract_descriptors(operations)
          operations.filter_map do |operation|
            type = operation.attributes[:type]
            next unless type.is_a?(Types::Descriptor)

            {
              node: operation.name,
              kind: operation.kind,
              type: serialize_value(type),
              enforced: false
            }
          end
        end

        def extract_return_types(operations)
          operations.filter_map do |operation|
            next unless operation.attribute?(:return_type)

            {
              node: operation.name,
              kind: operation.kind,
              return_type: serialize_value(operation.attributes[:return_type]),
              enforced: false
            }
          end
        end

        def extract_budgets(operations)
          operations.filter_map do |operation|
            deadline = operation.attributes[:deadline]
            wcet = operation.attributes[:wcet]
            next unless deadline || wcet

            entry = {
              node: operation.name,
              kind: operation.kind,
              enforced: false
            }
            entry[:deadline] = serialize_value(deadline) if deadline
            entry[:wcet] = serialize_value(wcet) if wcet
            entry
          end
        end

        def serialize_value(value)
          case value
          when Types::Descriptor
            value.to_h
          when Module
            value.name
          when Array
            value.map { |entry| serialize_value(entry) }
          when Hash
            value.to_h { |key, entry| [key.respond_to?(:to_sym) ? key.to_sym : key, serialize_value(entry)] }
          else
            value.respond_to?(:to_h) && !value.is_a?(Numeric) ? value.to_h : value
          end
        end
      end

      private

      def freeze_entries(entries)
        entries.map { |entry| deep_freeze(entry) }.freeze
      end

      def deep_freeze(value)
        case value
        when Array
          value.map { |entry| deep_freeze(entry) }.freeze
        when Hash
          value.transform_values { |entry| deep_freeze(entry) }.freeze
        else
          value.freeze
        end
      end
    end
  end
end
