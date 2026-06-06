# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Creator
        class Scope
          PRESETS = {
            app_local: {
              root: "app/lib",
              spec_root: "spec/lib",
              example_root: "examples",
              readme_path: "docs/igniter-packs/README.md",
              packaging_hints: [
                "keep the pack close to the host app while the API is still moving",
                "prefer app-local namespacing before extracting a shared gem"
              ]
            },
            monorepo_package: {
              root: "lib",
              spec_root: "spec",
              example_root: "examples",
              readme_path: "README.md",
              packaging_hints: [
                "add package-owned specs and a runnable example before promoting the pack",
                "keep the public entrypoint independent from igniter-core and contracts internals"
              ]
            },
            standalone_gem: {
              root: "lib",
              spec_root: "spec",
              example_root: "examples",
              readme_path: "README.md",
              packaging_hints: [
                "publish only after the pack has a stable public entrypoint and package-owned example",
                "treat the pack as a distributable gem with a small explicit surface"
              ]
            }
          }.freeze

          attr_reader :name, :root, :spec_root, :example_root, :readme_path, :packaging_hints

          def self.available
            PRESETS.keys
          end

          def self.build(scope)
            preset = PRESETS.fetch(scope.to_sym) do
              raise ArgumentError, "unknown creator scope #{scope.inspect}"
            end

            new(name: scope, **preset)
          end

          def initialize(name:, root:, spec_root:, example_root:, readme_path:, packaging_hints:)
            @name = name.to_sym
            @root = root
            @spec_root = spec_root
            @example_root = example_root
            @readme_path = readme_path
            @packaging_hints = packaging_hints.dup.freeze
            freeze
          end

          def to_h
            {
              name: name,
              root: root,
              spec_root: spec_root,
              example_root: example_root,
              readme_path: readme_path,
              packaging_hints: packaging_hints
            }
          end
        end
      end
    end
  end
end
