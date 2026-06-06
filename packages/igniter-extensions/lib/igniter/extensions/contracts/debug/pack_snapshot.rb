# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Debug
        class PackSnapshot
          attr_reader :manifest

          def initialize(manifest)
            @manifest = manifest
            freeze
          end

          def name
            manifest.name
          end

          def metadata
            manifest.metadata
          end

          def node_kinds
            manifest.node_contracts.map(&:kind)
          end

          def registry_contracts
            manifest.registry_contracts.each_with_object({}) do |contract, memo|
              memo[contract.registry] ||= []
              memo[contract.registry] << contract.key
            end.transform_values(&:sort)
          end

          def to_h
            {
              name: name,
              metadata: metadata,
              node_kinds: node_kinds,
              registry_contracts: registry_contracts
            }
          end
        end
      end
    end
  end
end
