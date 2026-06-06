# frozen_string_literal: true

module Igniter
  module DurableModel
    # Mixin for append-only event streams backed by History[T].
    #
    # DSL:
    #   history_name :tracker_logs   # storage namespace (defaults to lowercased class name)
    #   field :tracker_id            # event payload fields
    #   field :value
    #
    # Usage via Igniter::DurableModel::Store:
    #   store.append(TrackerLog, tracker_id: "t1", value: 8.5)
    #   store.replay(TrackerLog)  # => [#<TrackerLog ...>, ...]
    module History
      def self.included(base)
        base.extend(ClassMethods)
        base.instance_variable_set(:@_fields, {})
      end

      module ClassMethods
        def history_name(name = nil)
          if name
            @_history_name = name
          else
            @_history_name ||= self.name&.split("::")&.last&.downcase&.to_sym || :events
          end
        end
        alias_method :store_name, :history_name

        # Declares the field whose value partitions the event stream.
        # Enables Store#replay(partition:) to filter by a specific partition value.
        #   partition_key :tracker_id  →  store.replay(TrackerLog, partition: "sleep")
        def partition_key(name = nil)
          if name
            @_partition_key = name
          else
            @_partition_key
          end
        end

        def field(name, default: nil, type: nil, values: nil)
          @_fields ||= {}
          @_fields[name] = { default: default, type: type, values: values }
          attr_reader name
        end

        def _fields;       @_fields       ||= {}; end
        def _partition_key; @_partition_key; end

        def from_fact(fact)
          new(fact_id: fact.id, timestamp: fact.timestamp, **fact.value)
        end
      end

      # Build an anonymous History class from a persistence_manifest hash.
      # Manifest structure:
      #   storage: { shape: :history, name: :tracker_logs, key: :tracker_id, adapter: ... }
      #   history: { key: :tracker_id, ... }
      #   fields:  [{ name: :tracker_id, attributes: {} }, ...]
      #
      # The partition_key is taken from history.key (falls back to storage.key).
      # `store:` is optional when `manifest[:storage][:name]` is present.
      #
      # Usage:
      #   klass = Igniter::DurableModel::History.from_manifest(manifest)
      #   klass = Igniter::DurableModel::History.from_manifest(manifest, store: :override)
      def self.from_manifest(manifest, store: nil)
        resolved_store = store || manifest.dig(:storage, :name) ||
                         raise(ArgumentError, "store: is required when manifest has no storage.name")
        Class.new do
          include Igniter::DurableModel::History
          history_name resolved_store

          pk = manifest.dig(:history, :key) || manifest.dig(:storage, :key)
          partition_key pk if pk

          manifest.fetch(:fields, []).each do |field_def|
            attrs = field_def.fetch(:attributes, {})
            field field_def.fetch(:name),
                  default: attrs[:default],
                  type:    attrs[:type],
                  values:  attrs[:values]
          end
        end
      end

      attr_reader :fact_id, :timestamp

      def initialize(fact_id: nil, timestamp: nil, **attrs)
        @fact_id   = fact_id
        @timestamp = timestamp
        self.class._fields.each do |name, opts|
          val = attrs.key?(name) ? attrs[name] : opts[:default]
          instance_variable_set(:"@#{name}", val)
        end
      end

      def to_h
        self.class._fields.keys.each_with_object({}) do |name, h|
          h[name] = public_send(name)
        end
      end

      def inspect
        fields = self.class._fields.keys.map { |n| "#{n}=#{public_send(n).inspect}" }.join(" ")
        "#<#{self.class.name} fact_id=#{@fact_id&.slice(0, 8)} #{fields}>"
      end
    end
  end
end
