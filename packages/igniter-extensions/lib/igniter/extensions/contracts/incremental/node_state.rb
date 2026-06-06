# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Incremental
        class NodeState
          attr_reader :name, :value, :value_version, :dep_snapshot

          def initialize(name:, value:, value_version:, dep_snapshot: {})
            @name = name.to_sym
            @value = value
            @value_version = Integer(value_version)
            @dep_snapshot = dep_snapshot.transform_keys(&:to_sym).freeze
            freeze
          end

          def to_h
            {
              name: name,
              value: value,
              value_version: value_version,
              dep_snapshot: dep_snapshot
            }
          end
        end
      end
    end
  end
end
