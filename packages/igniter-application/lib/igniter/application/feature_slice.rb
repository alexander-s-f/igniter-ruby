# frozen_string_literal: true

module Igniter
  module Application
    class FeatureSlice
      attr_reader :name, :groups, :paths, :contracts, :services, :interfaces,
                  :exports, :imports, :flows, :surfaces, :metadata

      def initialize(name:, groups: [], paths: {}, contracts: [], services: [], interfaces: [],
                     exports: [], imports: [], flows: [], surfaces: [], metadata: {})
        @name = name.to_sym
        @groups = Array(groups).map(&:to_sym).uniq.sort.freeze
        @paths = symbolize_paths(paths).freeze
        @contracts = Array(contracts).map(&:to_s).freeze
        @services = Array(services).map(&:to_sym).freeze
        @interfaces = Array(interfaces).map(&:to_sym).freeze
        @exports = Array(exports).map(&:to_sym).freeze
        @imports = Array(imports).map(&:to_sym).freeze
        @flows = Array(flows).map(&:to_sym).freeze
        @surfaces = Array(surfaces).map(&:to_sym).freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def self.from(value)
        return value if value.is_a?(self)

        new(**symbolize_keys(value))
      end

      def to_h
        {
          name: name,
          groups: groups.dup,
          paths: paths.dup,
          contracts: contracts.dup,
          services: services.dup,
          interfaces: interfaces.dup,
          exports: exports.dup,
          imports: imports.dup,
          flows: flows.dup,
          surfaces: surfaces.dup,
          metadata: metadata.dup
        }
      end

      def self.symbolize_keys(value)
        value.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end
      private_class_method :symbolize_keys

      private

      def symbolize_paths(value)
        value.to_h.each_with_object({}) do |(key, path), result|
          result[key.to_sym] = path.to_s
        end
      end
    end
  end
end
