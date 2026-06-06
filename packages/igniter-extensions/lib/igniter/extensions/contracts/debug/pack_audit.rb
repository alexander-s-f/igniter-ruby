# frozen_string_literal: true

require_relative "pack_snapshot"

module Igniter
  module Extensions
    module Contracts
      module Debug
        class PackAudit
          REGISTRIES = {
            node_kinds: ->(kernel) { kernel.nodes.to_h.keys.sort },
            dsl_keywords: ->(kernel) { kernel.dsl_keywords.to_h.keys.sort },
            validators: ->(kernel) { kernel.validators.entries.map(&:key).sort },
            normalizers: ->(kernel) { kernel.normalizers.entries.map(&:key).sort },
            runtime_handlers: ->(kernel) { kernel.runtime_handlers.to_h.keys.sort },
            diagnostics_contributors: ->(kernel) { kernel.diagnostics_contributors.entries.map(&:key).sort },
            effects: ->(kernel) { kernel.effects.to_h.keys.sort },
            executors: ->(kernel) { kernel.executors.to_h.keys.sort }
          }.freeze

          attr_reader :pack_snapshot,
                      :installed_in_target_profile,
                      :target_profile_fingerprint,
                      :draft_registered_keys,
                      :missing_node_definitions,
                      :missing_dsl_keywords,
                      :missing_runtime_handlers,
                      :missing_registry_contracts,
                      :install_error,
                      :finalize_error

          def self.build(pack, profile: nil)
            manifest = pack.manifest
            baseline_snapshot = registry_snapshot(Igniter::Contracts.build_kernel)
            draft_snapshot, install_error = install_snapshot(pack)

            new(
              pack_snapshot: PackSnapshot.new(manifest),
              installed_in_target_profile: profile ? profile.pack_names.include?(manifest.name) : false,
              target_profile_fingerprint: profile&.fingerprint,
              draft_registered_keys: registry_delta(baseline_snapshot, draft_snapshot),
              missing_node_definitions: missing_node_definitions(manifest, draft_snapshot),
              missing_dsl_keywords: missing_dsl_keywords(manifest, draft_snapshot),
              missing_runtime_handlers: missing_runtime_handlers(manifest, draft_snapshot),
              missing_registry_contracts: missing_registry_contracts(manifest, draft_snapshot),
              install_error: install_error,
              finalize_error: finalize_error_for(pack)
            )
          end

          def self.install_snapshot(pack)
            kernel = Igniter::Contracts.build_kernel
            error = nil

            begin
              kernel.install(pack)
            rescue StandardError => e
              error = "#{e.class}: #{e.message}"
            end

            [registry_snapshot(kernel), error]
          end

          def self.finalize_error_for(pack)
            kernel = Igniter::Contracts.build_kernel
            kernel.install(pack)
            kernel.finalize
            nil
          rescue StandardError => e
            "#{e.class}: #{e.message}"
          end

          def self.registry_snapshot(kernel)
            REGISTRIES.to_h { |name, reader| [name, reader.call(kernel)] }
          end

          def self.registry_delta(before, after)
            REGISTRIES.keys.to_h do |name|
              [name, after.fetch(name) - before.fetch(name)]
            end
          end

          def self.missing_node_definitions(manifest, snapshot)
            manifest.node_contracts.map(&:kind).reject { |kind| snapshot.fetch(:node_kinds).include?(kind) }
          end

          def self.missing_dsl_keywords(manifest, snapshot)
            required = manifest.node_contracts.select(&:requires_dsl).map(&:kind)
            required.reject { |kind| snapshot.fetch(:dsl_keywords).include?(kind) }
          end

          def self.missing_runtime_handlers(manifest, snapshot)
            required = manifest.node_contracts.select(&:requires_runtime).map(&:kind)
            required.reject { |kind| snapshot.fetch(:runtime_handlers).include?(kind) }
          end

          def self.missing_registry_contracts(manifest, snapshot)
            manifest.registry_contracts.each_with_object({}) do |contract, memo|
              registry = normalize_registry(contract.registry)
              available = snapshot.fetch(registry)
              next if available.include?(contract.key)

              memo[registry] ||= []
              memo[registry] << contract.key
            end.transform_values(&:sort)
          end

          def self.normalize_registry(name)
            case name.to_sym
            when :nodes
              :node_kinds
            else
              name.to_sym
            end
          end

          def initialize(pack_snapshot:, installed_in_target_profile:, target_profile_fingerprint:,
                         draft_registered_keys:, missing_node_definitions:, missing_dsl_keywords:, missing_runtime_handlers:, missing_registry_contracts:, install_error:, finalize_error:)
            @pack_snapshot = pack_snapshot
            @installed_in_target_profile = installed_in_target_profile
            @target_profile_fingerprint = target_profile_fingerprint
            @draft_registered_keys = draft_registered_keys
            @missing_node_definitions = missing_node_definitions.freeze
            @missing_dsl_keywords = missing_dsl_keywords.freeze
            @missing_runtime_handlers = missing_runtime_handlers.freeze
            @missing_registry_contracts = missing_registry_contracts.transform_values(&:freeze).freeze
            @install_error = install_error
            @finalize_error = finalize_error
            freeze
          end

          def name
            pack_snapshot.name
          end

          def ok?
            install_error.nil? &&
              finalize_error.nil? &&
              missing_node_definitions.empty? &&
              missing_dsl_keywords.empty? &&
              missing_runtime_handlers.empty? &&
              missing_registry_contracts.empty?
          end

          def to_h
            {
              pack: pack_snapshot.to_h,
              installed_in_target_profile: installed_in_target_profile,
              target_profile_fingerprint: target_profile_fingerprint,
              draft_registered_keys: draft_registered_keys,
              missing: {
                node_definitions: missing_node_definitions,
                dsl_keywords: missing_dsl_keywords,
                runtime_handlers: missing_runtime_handlers,
                registry_contracts: missing_registry_contracts
              },
              install_error: install_error,
              finalize_error: finalize_error,
              ok: ok?
            }
          end

          def explain
            return "#{name} looks complete" if ok?

            parts = []
            parts << "install_error=#{install_error}" if install_error
            parts << "missing node definitions: #{missing_node_definitions.join(", ")}" unless missing_node_definitions.empty?
            parts << "missing DSL keywords: #{missing_dsl_keywords.join(", ")}" unless missing_dsl_keywords.empty?
            parts << "missing runtime handlers: #{missing_runtime_handlers.join(", ")}" unless missing_runtime_handlers.empty?
            missing_registry_contracts.each do |registry, keys|
              parts << "missing #{registry}: #{keys.join(", ")}"
            end
            parts << "finalize_error=#{finalize_error}" if finalize_error
            parts.join("; ")
          end
        end
      end
    end
  end
end
