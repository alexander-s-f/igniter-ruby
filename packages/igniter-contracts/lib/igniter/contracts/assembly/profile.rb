# frozen_string_literal: true

require "digest"

module Igniter
  module Contracts
    module Assembly
      class Profile
        attr_reader :nodes,
                    :dsl_keywords,
                    :validators,
                    :normalizers,
                    :runtime_handlers,
                    :diagnostics_contributors,
                    :pack_manifests,
                    :effects,
                    :executors,
                    :fingerprint

        def self.build_from(kernel)
          payload = {
            nodes: kernel.nodes.to_h.freeze,
            dsl_keywords: kernel.dsl_keywords.to_h.freeze,
            validators: kernel.validators.entries.freeze,
            normalizers: kernel.normalizers.entries.freeze,
            runtime_handlers: kernel.runtime_handlers.to_h.freeze,
            diagnostics_contributors: kernel.diagnostics_contributors.entries.freeze,
            pack_manifests: kernel.pack_manifests.dup.freeze,
            effects: kernel.effects.to_h.freeze,
            executors: kernel.executors.to_h.freeze
          }

          new(**payload, fingerprint: fingerprint_for(payload))
        end

        def self.fingerprint_for(payload)
          normalized = payload.map do |key, value|
            serialized = serialize_for_fingerprint(value)
            [key.to_s, serialized]
          end

          Digest::SHA256.hexdigest(normalized.inspect)
        end

        def self.serialize_for_fingerprint(value)
          case value
          when Hash
            value.map { |entry_key, entry_value| [entry_key.to_s, entry_value.inspect] }
          when Array
            value.map do |entry|
              if entry.respond_to?(:key) && entry.respond_to?(:value)
                [entry.key.to_s, entry.value.inspect]
              else
                entry.inspect
              end
            end
          else
            value.inspect
          end
        end

        def initialize(nodes:, dsl_keywords:, validators:, normalizers:, runtime_handlers:, diagnostics_contributors:,
                       pack_manifests:, effects:, executors:, fingerprint:)
          @nodes = nodes
          @dsl_keywords = dsl_keywords
          @validators = validators
          @normalizers = normalizers
          @runtime_handlers = runtime_handlers
          @diagnostics_contributors = diagnostics_contributors
          @pack_manifests = pack_manifests
          @effects = effects
          @executors = executors
          @fingerprint = fingerprint
          freeze
        end

        def node_class(kind)
          nodes.fetch(kind.to_sym)
        end

        def dsl_keyword(name)
          dsl_keywords.fetch(name.to_sym)
        end

        def runtime_handler(kind)
          runtime_handlers.fetch(kind.to_sym)
        end

        def effect(name)
          effects.fetch(name.to_sym)
        end

        def executor(name)
          executors.fetch(name.to_sym)
        end

        def supports_node_kind?(kind)
          nodes.key?(kind.to_sym)
        end

        def supports_effect?(name)
          effects.key?(name.to_sym)
        end

        def supports_executor?(name)
          executors.key?(name.to_sym)
        end

        def pack_names
          pack_manifests.map(&:name)
        end

        def pack_manifest(name)
          pack_manifests.find { |manifest| manifest.name == name.to_sym }
        end

        def provided_capabilities
          pack_manifests.flat_map(&:provides_capabilities).uniq
        end

        def required_capabilities
          pack_manifests.flat_map(&:requires_capabilities).uniq
        end

        def declared_registry_keys(registry)
          pack_manifests
            .flat_map { |manifest| manifest.declared_keys_for(registry) }
            .uniq
        end
      end
    end
  end
end
