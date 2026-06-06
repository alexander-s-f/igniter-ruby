# frozen_string_literal: true

require_relative "capabilities/declaration"
require_relative "capabilities/violation"
require_relative "capabilities/report"
require_relative "capabilities/policy"
require_relative "capabilities/error"

module Igniter
  module Extensions
    module Contracts
      module CapabilitiesPack
        module_function

        def manifest
          Igniter::Contracts::PackManifest.new(
            name: :extensions_capabilities,
            metadata: { category: :validation }
          )
        end

        def install_into(kernel)
          kernel
        end

        def declare(*capabilities, callable: nil, &block)
          target = callable || block
          raise ArgumentError, "capability declaration requires a callable or block" unless target

          Capabilities::Declaration.new(callable: target, capabilities: capabilities)
        end

        def pure(callable: nil, &block)
          declare(:pure, callable: callable, &block)
        end

        def policy(denied: [], required: [], on_undeclared: :ignore)
          Capabilities::Policy.new(
            denied: denied,
            required: required,
            on_undeclared: on_undeclared
          )
        end

        def required_capabilities(compiled_graph)
          compiled_graph.operations.reject(&:output?).each_with_object({}) do |operation, memo|
            capabilities = capabilities_for_operation(operation)
            memo[operation.name] = capabilities unless capabilities.empty?
          end
        end

        def capabilities_for(compiled_graph, node_name)
          operation = compiled_graph.operations.find { |entry| entry.name == node_name.to_sym }
          return [] unless operation

          capabilities_for_operation(operation)
        end

        def profile_capabilities(profile)
          profile.pack_manifests
                 .flat_map do |manifest_entry|
                   manifest_entry.provides_capabilities.empty? ? Array(manifest_entry.metadata[:capabilities]) : manifest_entry.provides_capabilities
                 end
                 .map(&:to_sym)
                 .uniq
        end

        def report(compiled_graph, profile: nil, policy: nil)
          requirements = required_capabilities(compiled_graph)
          undeclared_nodes = compiled_graph.operations.reject(&:output?).map(&:name) - requirements.keys
          violations = violations_for(requirements, policy: policy, undeclared_nodes: undeclared_nodes)
          maybe_warn_about_undeclared(policy, undeclared_nodes)

          Capabilities::Report.new(
            required_capabilities: requirements,
            profile_capabilities: profile ? profile_capabilities(profile) : [],
            violations: violations,
            undeclared_nodes: undeclared_nodes
          )
        end

        def check!(compiled_graph, policy:, profile: nil)
          result = report(compiled_graph, profile: profile, policy: policy)
          raise Capabilities::CapabilityViolationError.new(nil, report: result) if result.invalid?

          result
        end

        def capabilities_for_operation(operation)
          capabilities = Array(operation.attributes[:capabilities]).map(&:to_sym)
          callable = operation.attributes[:callable]
          capabilities.concat(Array(callable.declared_capabilities).map(&:to_sym)) if callable.respond_to?(:declared_capabilities)
          capabilities.uniq
        end

        def violations_for(requirements, policy:, undeclared_nodes:)
          return [] unless policy

          violations = []

          requirements.each do |node_name, capabilities|
            denied = capabilities & policy.denied
            if denied.any?
              violations << Capabilities::Violation.new(
                kind: :denied_capability,
                node_name: node_name,
                capabilities: denied,
                message: "node #{node_name} uses denied capabilities: #{denied.join(", ")}"
              )
            end

            missing = policy.required - capabilities
            next unless missing.any?

            violations << Capabilities::Violation.new(
              kind: :missing_required_capability,
              node_name: node_name,
              capabilities: missing,
              message: "node #{node_name} is missing required capabilities: #{missing.join(", ")}"
            )
          end

          if policy.on_undeclared == :error
            undeclared_nodes.each do |node_name|
              violations << Capabilities::Violation.new(
                kind: :undeclared_capabilities,
                node_name: node_name,
                capabilities: [],
                message: "node #{node_name} does not declare capabilities"
              )
            end
          end

          violations
        end

        def maybe_warn_about_undeclared(policy, undeclared_nodes)
          return unless policy&.on_undeclared == :warn
          return if undeclared_nodes.empty?

          Warning.warn("WARNING: undeclared capabilities for nodes: #{undeclared_nodes.join(", ")}\n")
        end
      end
    end
  end
end
