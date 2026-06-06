# frozen_string_literal: true

require_relative "pack_snapshot"

module Igniter
  module Extensions
    module Contracts
      module Debug
        class ProfileSnapshot
          attr_reader :profile

          def initialize(profile:)
            @profile = profile
            freeze
          end

          def pack_names
            profile.pack_names.sort
          end

          def packs
            profile.pack_manifests.map { |manifest| PackSnapshot.new(manifest) }
          end

          def registry_keys
            {
              node_kinds: profile.nodes.keys.sort,
              dsl_keywords: profile.dsl_keywords.keys.sort,
              validators: profile.validators.map(&:key).sort,
              normalizers: profile.normalizers.map(&:key).sort,
              runtime_handlers: profile.runtime_handlers.keys.sort,
              diagnostics_contributors: profile.diagnostics_contributors.map(&:key).sort,
              effects: profile.effects.keys.sort,
              executors: profile.executors.keys.sort
            }
          end

          def to_h
            {
              fingerprint: profile.fingerprint,
              pack_names: pack_names,
              registry_keys: registry_keys,
              packs: packs.map(&:to_h)
            }
          end
        end
      end
    end
  end
end
