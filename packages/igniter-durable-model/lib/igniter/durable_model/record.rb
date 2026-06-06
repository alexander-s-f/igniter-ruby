# frozen_string_literal: true

module Igniter
  module DurableModel
    # Mixin that turns a plain Ruby class into a Record type backed by Store[T].
    #
    # DSL:
    #   store_name :reminders           # storage namespace key (defaults to lowercased class name)
    #   field :title                    # declares a readable attribute
    #   field :status, default: :open   # with default filled in on read
    #   scope :open, filters: { status: :open }
    #   scope :open, filters: {...}, cache_ttl: 30
    #
    # Usage via Igniter::DurableModel::Store:
    #   store.write(Reminder, key: "r1", title: "Buy milk")
    #   store.read(Reminder, key: "r1")   # => #<Reminder key="r1" title="Buy milk" status=:open>
    #   store.scope(Reminder, :open)       # => [#<Reminder ...>, ...]
    module Record
      def self.included(base)
        base.extend(ClassMethods)
        base.instance_variable_set(:@_fields, {})
        base.instance_variable_set(:@_scopes, {})
      end

      module ClassMethods
        def store_name(name = nil)
          if name
            @store_name = name
          else
            @store_name ||= self.name&.split("::")&.last&.downcase&.to_sym || :records
          end
        end

        def field(name, default: nil, type: nil, values: nil)
          @_fields ||= {}
          @_fields[name] = { default: default, type: type, values: values }
          attr_reader name
        end

        def scope(name, filters:, cache_ttl: nil)
          @_scopes ||= {}
          @_scopes[name] = { filters: filters, cache_ttl: cache_ttl }
        end

        def index(name, fields:, unique: false)
          @_indexes ||= {}
          @_indexes[name] = { fields: Array(fields).map(&:to_sym), unique: unique }
        end

        def command(name, **attrs)
          @_commands ||= {}
          @_commands[name] = attrs
        end

        def relation(name, **attrs)
          @_relations ||= {}
          @_relations[name] = attrs
        end

        def _fields = @_fields ||= {}
        def _scopes = @_scopes ||= {}
        def _indexes = @_indexes ||= {}
        def _commands = @_commands ||= {}
        def _relations = @_relations ||= {}

        # Derived from _commands: maps each command to its store-level effect.
        # Applies the same operation → store_op mapping as the effect_intent plan.
        # Metadata-only — no store-side execution.
        def _effects
          @_effects ||= _commands.transform_values do |attrs|
            data = attrs.to_h.transform_keys(&:to_sym)
            op = data[:operation].is_a?(String) ? data[:operation].to_sym : data[:operation]
            EFFECT_KIND_MAP.fetch(op, EFFECT_KIND_MAP[:__unknown__]).merge(source_operation: op)
          end
        end

        EFFECT_KIND_MAP = {
          record_append: { store_op: :store_write,  write_kind: :insert, lowers_to: :store_t  },
          record_update: { store_op: :store_write,  write_kind: :update, lowers_to: :store_t  },
          history_append: { store_op: :store_append, write_kind: :append, lowers_to: :history_t },
          __unknown__: { store_op: :none, write_kind: :none, lowers_to: :none }
        }.freeze

        def from_fact(fact)
          new(key: fact.key, **fact.value)
        end
      end

      # Build an anonymous Record class from a persistence_manifest hash.
      # Manifest structure (from app-local contract DSL):
      #   storage: { shape: :store, name: :reminders, key: :id, adapter: ... }
      #   fields:  [{ name: :title, attributes: {} },
      #             { name: :status, attributes: { default: :open } }, ...]
      #   scopes:  [{ name: :open, attributes: { where: { status: :open } } }, ...]
      #
      # `store:` is optional when `manifest[:storage][:name]` is present.
      #
      # Usage:
      #   klass = Igniter::DurableModel::Record.from_manifest(manifest)
      #   klass = Igniter::DurableModel::Record.from_manifest(manifest, store: :override)
      def self.from_manifest(manifest, store: nil)
        resolved_store = store || manifest.dig(:storage, :name) ||
                         raise(ArgumentError, "store: is required when manifest has no storage.name")
        Class.new do
          include Igniter::DurableModel::Record
          store_name resolved_store

          manifest.fetch(:fields, []).each do |field_def|
            attrs = field_def.fetch(:attributes, {})
            field field_def.fetch(:name),
                  default: attrs[:default],
                  type: attrs[:type],
                  values: attrs[:values]
          end

          manifest.fetch(:scopes, []).each do |scope_def|
            filters = scope_def.fetch(:attributes, {}).fetch(:where, {})
            scope scope_def.fetch(:name), filters: filters
          end

          manifest.fetch(:indexes, []).each do |index_def|
            attrs  = index_def.fetch(:attributes, {})
            fields = Array(attrs.fetch(:fields, index_def.fetch(:name))).map(&:to_sym)
            index index_def.fetch(:name),
                  fields: fields,
                  unique: attrs.fetch(:unique, false)
          end

          manifest.fetch(:commands, []).each do |command_def|
            attrs = command_def.fetch(:attributes, {})
            command command_def.fetch(:name), **attrs
          end

          manifest.fetch(:relations, []).each do |relation_def|
            attrs = relation_def.fetch(:attributes, {})
            relation relation_def.fetch(:name), **attrs
          end
        end
      end

      attr_reader :key

      def initialize(key:, **attrs)
        @key = key
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
        "#<#{self.class.name} key=#{@key.inspect} #{fields}>"
      end
    end
  end
end
