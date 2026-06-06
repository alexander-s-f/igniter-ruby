# frozen_string_literal: true

module Igniter
  module Contracts
    module Assembly
      class PackManifest
        RegistryContract = Struct.new(:registry, :key, keyword_init: true) do
          def initialize(registry:, key:)
            super(
              registry: registry.to_sym,
              key: key.to_sym
            )
          end
        end

        NodeContract = Struct.new(:kind, :requires_dsl, :requires_runtime, keyword_init: true) do
          def initialize(kind:, requires_dsl: true, requires_runtime: true)
            super(
              kind: kind.to_sym,
              requires_dsl: requires_dsl,
              requires_runtime: requires_runtime
            )
          end
        end

        PackDependency = Struct.new(:name, :pack, keyword_init: true) do
          def initialize(name:, pack: nil)
            super(
              name: name.to_sym,
              pack: pack
            )
          end
        end

        class << self
          def node(kind, requires_dsl: true, requires_runtime: true)
            NodeContract.new(
              kind: kind,
              requires_dsl: requires_dsl,
              requires_runtime: requires_runtime
            )
          end

          def registry(registry, key)
            RegistryContract.new(registry: registry, key: key)
          end

          def dsl_keyword(key)
            registry(:dsl_keywords, key)
          end

          def runtime_handler(key)
            registry(:runtime_handlers, key)
          end

          def validator(key)
            registry(:validators, key)
          end

          def normalizer(key)
            registry(:normalizers, key)
          end

          def diagnostic(key)
            registry(:diagnostics_contributors, key)
          end

          def effect(key)
            registry(:effects, key)
          end

          def executor(key)
            registry(:executors, key)
          end

          def pack_dependency(pack_or_name, pack: nil)
            return PackDependency.new(name: pack_or_name, pack: pack) if pack

            if pack_or_name.respond_to?(:manifest)
              manifest = pack_or_name.manifest
              return PackDependency.new(name: manifest.name, pack: pack_or_name)
            end

            PackDependency.new(name: pack_or_name)
          end
        end

        attr_reader :name, :node_contracts, :registry_contracts, :metadata,
                    :requires_packs, :provides_capabilities, :requires_capabilities

        def initialize(name:, node_contracts: [], registry_contracts: [], diagnostics: [], metadata: {},
                       requires_packs: [], provides_capabilities: [], requires_capabilities: [])
          @name = name.to_sym
          @node_contracts = node_contracts.freeze
          @registry_contracts = (
            registry_contracts +
            diagnostics.map { |key| self.class.diagnostic(key) }
          ).uniq.freeze
          @metadata = metadata.freeze
          @requires_packs = normalize_pack_dependencies(requires_packs)
          @provides_capabilities = normalize_capabilities(provides_capabilities)
          @requires_capabilities = normalize_capabilities(requires_capabilities)
          freeze
        end

        def declared_keys_for(registry)
          registry_contracts
            .select { |contract| contract.registry == registry.to_sym }
            .map(&:key)
        end

        def diagnostics
          declared_keys_for(:diagnostics_contributors)
        end

        private

        def normalize_pack_dependencies(dependencies)
          Array(dependencies)
            .map { |entry| entry.is_a?(PackDependency) ? entry : self.class.pack_dependency(entry) }
            .uniq(&:name)
            .freeze
        end

        def normalize_capabilities(capabilities)
          Array(capabilities).flatten.compact.map(&:to_sym).uniq.freeze
        end
      end
    end
  end
end
