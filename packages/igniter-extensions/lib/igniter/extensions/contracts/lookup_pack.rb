# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module LookupPack
        module_function

        def manifest
          Igniter::Contracts::PackManifest.new(
            name: :extensions_lookup,
            registry_contracts: [Igniter::Contracts::PackManifest.dsl_keyword(:lookup)]
          )
        end

        def install_into(kernel)
          kernel.dsl_keywords.register(:lookup, lookup_keyword)
          kernel
        end

        def lookup_keyword
          Igniter::Contracts::DslKeyword.new(:lookup) do |name, from:, builder:, key: nil, dig: nil, default: Igniter::Contracts::PathAccess::NO_DEFAULT|
            source_name = from.to_sym
            path = Igniter::Contracts::PathAccess.normalize_path(
              keyword_name: :lookup,
              key: key,
              dig: dig
            )

            builder.add_operation(
              kind: :compute,
              name: name,
              depends_on: [source_name],
              callable: lambda do |**values|
                source = values.fetch(source_name)
                Igniter::Contracts::PathAccess.fetch_path(
                  source,
                  path,
                  source_name: source_name,
                  keyword_name: :lookup,
                  default: default
                )
              end
            )
          end
        end
      end
    end
  end
end
