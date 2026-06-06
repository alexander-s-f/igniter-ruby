# frozen_string_literal: true

module Igniter
  module Contracts
    module Assembly
      class Kernel
        attr_reader :nodes,
                    :dsl_keywords,
                    :validators,
                    :normalizers,
                    :runtime_handlers,
                    :diagnostics_contributors,
                    :pack_manifests,
                    :effects,
                    :executors

        def initialize(
          nodes: Registry.new(name: :nodes),
          dsl_keywords: Registry.new(name: :dsl_keywords),
          validators: OrderedRegistry.new(name: :validators),
          normalizers: OrderedRegistry.new(name: :normalizers),
          runtime_handlers: Registry.new(name: :runtime_handlers),
          diagnostics_contributors: OrderedRegistry.new(name: :diagnostics_contributors),
          effects: Registry.new(name: :effects),
          executors: Registry.new(name: :executors)
        )
          @nodes = nodes
          @dsl_keywords = dsl_keywords
          @validators = validators
          @normalizers = normalizers
          @runtime_handlers = runtime_handlers
          @diagnostics_contributors = diagnostics_contributors
          @pack_manifests = []
          @effects = effects
          @executors = executors
          @finalized = false
        end

        def install(pack, installing: [])
          raise FrozenKernelError, "kernel already finalized" if finalized?

          manifest = pack.respond_to?(:manifest) ? pack.manifest : nil
          pack_name = manifest&.name

          return self if pack_name && pack_installed?(pack_name)

          if pack_name && installing.include?(pack_name)
            cycle = (installing + [pack_name]).join(" -> ")
            raise CircularPackDependencyError, "circular pack dependency detected: #{cycle}"
          end

          install_required_packs(manifest, installing: [*installing, pack_name].compact) if manifest
          register_pack_manifest(pack, manifest: manifest)
          pack.install_into(self)
          self
        end

        def finalize
          validate_completeness!
          validate_hook_implementations!
          freeze_registries!
          @finalized = true
          Profile.build_from(self)
        end

        def finalized?
          @finalized
        end

        private

        REGISTRY_LABELS = {
          dsl_keywords: "DSL keywords",
          validators: "validators",
          normalizers: "normalizers",
          runtime_handlers: "runtime handlers",
          diagnostics_contributors: "diagnostics contributors",
          effects: "effects",
          executors: "executors"
        }.freeze

        def register_pack_manifest(pack, manifest: nil)
          manifest ||= pack.respond_to?(:manifest) ? pack.manifest : nil
          return unless manifest

          pack_manifests << manifest
        end

        def pack_installed?(name)
          pack_manifests.any? { |manifest| manifest.name == name.to_sym }
        end

        def install_required_packs(manifest, installing:)
          manifest.requires_packs.each do |dependency|
            next if pack_installed?(dependency.name)

            unless dependency.pack
              raise UnknownPackDependencyError,
                    "pack #{manifest.name} requires pack #{dependency.name}, but no pack implementation was provided"
            end

            install(dependency.pack, installing: installing)
          end
        end

        def validate_completeness!
          manifest_contracts = pack_manifests.flat_map(&:node_contracts)
          undeclared_nodes = nodes.to_h.values.reject do |node|
            manifest_contracts.any? do |contract|
              contract.kind == node.kind
            end
          end
          undeclared_contracts = undeclared_nodes.map do |node|
            PackManifest.node(
              node.kind,
              requires_dsl: node.requires_dsl?,
              requires_runtime: node.requires_runtime?
            )
          end
          contracts = manifest_contracts + undeclared_contracts

          missing_node_definitions = manifest_contracts.map(&:kind).reject { |kind| nodes.registered?(kind) }
          missing_dsl = contracts.select(&:requires_dsl).map(&:kind).reject { |kind| dsl_keywords.registered?(kind) }
          missing_runtime = contracts.select(&:requires_runtime).map(&:kind).reject do |kind|
            runtime_handlers.registered?(kind)
          end
          missing_registry_contracts = collect_missing_registry_contracts
          return if missing_node_definitions.empty? &&
                    missing_dsl.empty? &&
                    missing_runtime.empty? &&
                    missing_registry_contracts.empty?

          parts = []
          parts << "missing node definitions for: #{missing_node_definitions.map(&:to_s).join(", ")}" unless missing_node_definitions.empty?
          parts << "missing DSL keywords for: #{missing_dsl.map(&:to_s).join(", ")}" unless missing_dsl.empty?
          parts << "missing runtime handlers for: #{missing_runtime.map(&:to_s).join(", ")}" unless missing_runtime.empty?
          parts.concat(missing_registry_contracts)

          raise IncompletePackError, parts.join("; ")
        end

        def validate_hook_implementations!
          HookSpecs.registry_names.each do |registry_name|
            hook_spec = HookSpecs.fetch(registry_name)

            each_registry_entry(registry_name) do |key, implementation|
              hook_spec.validate!(key, implementation)
            end
          end
        end

        def collect_missing_registry_contracts
          pack_manifests
            .flat_map(&:registry_contracts)
            .group_by(&:registry)
            .filter_map do |registry_name, contracts|
              registry = registry_for(registry_name)
              next if registry.nil?

              missing = contracts.map(&:key).reject { |key| registry.registered?(key) }
              next if missing.empty?

              missing_registry_message(registry_name, missing)
            end
        end

        def missing_registry_message(registry_name, missing)
          label = REGISTRY_LABELS.fetch(registry_name, registry_name.to_s.tr("_", " "))
          "missing #{label} for: #{missing.map(&:to_s).join(", ")}"
        end

        def registry_for(name)
          case name.to_sym
          when :dsl_keywords
            dsl_keywords
          when :validators
            validators
          when :normalizers
            normalizers
          when :runtime_handlers
            runtime_handlers
          when :diagnostics_contributors
            diagnostics_contributors
          when :effects
            effects
          when :executors
            executors
          end
        end

        def each_registry_entry(registry_name, &block)
          registry = registry_for(registry_name)
          return unless registry

          case registry
          when Registry
            registry.to_h.each(&block)
          when OrderedRegistry
            registry.entries.each do |entry|
              yield(entry.key, entry.value)
            end
          end
        end

        def freeze_registries!
          [
            nodes,
            dsl_keywords,
            validators,
            normalizers,
            runtime_handlers,
            diagnostics_contributors,
            effects,
            executors
          ].each(&:freeze!)
        end
      end
    end
  end
end
