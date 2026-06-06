# frozen_string_literal: true

module Igniter
  module Contracts
    module Assembly
      module ProjectPack
        module_function

        def manifest
          PackManifest.new(
            name: :project,
            registry_contracts: [PackManifest.dsl_keyword(:project)]
          )
        end

        def install_into(kernel)
          kernel.dsl_keywords.register(:project, DslKeyword.new(:project) do |name, from:, builder:, key: nil, dig: nil, default: PathAccess::NO_DEFAULT|
            source_name = from.to_sym
            path = PathAccess.normalize_path(keyword_name: :project, key: key, dig: dig)

            builder.add_operation(
              kind: :compute,
              name: name,
              depends_on: [source_name],
              callable: lambda do |**values|
                source = values.fetch(source_name)
                PathAccess.fetch_path(
                  source,
                  path,
                  source_name: source_name,
                  keyword_name: :project,
                  default: default
                )
              end
            )
          end)
          kernel
        end
      end
    end
  end
end
