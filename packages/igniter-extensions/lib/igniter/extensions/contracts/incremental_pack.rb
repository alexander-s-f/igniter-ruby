# frozen_string_literal: true

require_relative "incremental/node_state"
require_relative "incremental/formatter"
require_relative "incremental/result"
require_relative "incremental/session"

module Igniter
  module Extensions
    module Contracts
      module IncrementalPack
        module_function

        def manifest
          Igniter::Contracts::PackManifest.new(
            name: :extensions_incremental,
            metadata: { category: :orchestration }
          )
        end

        def install_into(kernel)
          kernel
        end

        def session(environment, compiled_graph: nil, &block)
          graph = compiled_graph || environment.compile(&block)
          ensure_installed!(environment.profile)
          Incremental::Session.new(compiled_graph: graph, profile: environment.profile)
        end

        def ensure_installed!(profile)
          return if profile.pack_names.include?(:extensions_incremental)

          raise Igniter::Contracts::Error,
                "IncrementalPack is not installed in profile #{profile.fingerprint}; add Igniter::Extensions::Contracts::IncrementalPack"
        end
      end
    end
  end
end
