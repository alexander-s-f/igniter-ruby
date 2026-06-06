# frozen_string_literal: true

require_relative "mcp/tool_definition"
require_relative "mcp/tool_argument"
require_relative "mcp/tool_result"
require_relative "mcp/creator_session"

module Igniter
  module Extensions
    module Contracts
      module McpPack
        module_function

        def manifest
          Igniter::Contracts::PackManifest.new(
            name: :extensions_mcp,
            requires_packs: [DebugPack, CreatorPack],
            metadata: { category: :tooling }
          )
        end

        def install_into(kernel)
          kernel
        end

        def tools
          @tools ||= [
            Mcp::ToolDefinition.new(
              name: :inspect_profile,
              summary: "Return a structured profile snapshot.",
              target: :profile_or_environment
            ),
            Mcp::ToolDefinition.new(
              name: :inspect_pack,
              summary: "Return a structured installed-pack snapshot.",
              target: :profile_or_environment,
              arguments: [
                Mcp::ToolArgument.new(name: :pack, type: :pack_reference,
                                      summary: "Installed pack name or pack module.", required: true)
              ]
            ),
            Mcp::ToolDefinition.new(
              name: :audit_pack,
              summary: "Audit a custom pack against creator/debug quality seams.",
              target: :optional_profile_or_environment,
              arguments: [
                Mcp::ToolArgument.new(name: :pack, type: :pack_reference, summary: "Custom pack module to audit.",
                                      required: true)
              ]
            ),
            Mcp::ToolDefinition.new(
              name: :debug_report,
              summary: "Compile or execute and return a structured debug report.",
              target: :environment,
              arguments: [
                Mcp::ToolArgument.new(name: :inputs, type: :map,
                                      summary: "Runtime inputs used for execution when a graph is available."),
                Mcp::ToolArgument.new(name: :compiled_graph, type: :compiled_graph,
                                      summary: "Previously compiled graph to execute instead of compiling a block.")
              ]
            ),
            Mcp::ToolDefinition.new(
              name: :creator_wizard,
              summary: "Build a stateful creator wizard payload.",
              target: :optional_profile_or_environment,
              arguments: creator_arguments(include_scope: true, include_root: true)
            ),
            Mcp::ToolDefinition.new(
              name: :creator_session_start,
              summary: "Create a serialized creator session payload.",
              target: :optional_profile_or_environment,
              arguments: creator_arguments(include_scope: true, include_root: true)
            ),
            Mcp::ToolDefinition.new(
              name: :creator_session_apply,
              summary: "Apply updates to a serialized creator session payload.",
              target: :optional_profile_or_environment,
              arguments: [
                Mcp::ToolArgument.new(name: :session, type: :session_state,
                                      summary: "Previously serialized creator session payload.", required: true),
                Mcp::ToolArgument.new(name: :updates, type: :map,
                                      summary: "Partial wizard updates to merge into the session.", required: true)
              ]
            ),
            Mcp::ToolDefinition.new(
              name: :creator_session_workflow,
              summary: "Build workflow payload from a serialized creator session.",
              target: :optional_profile_or_environment,
              arguments: [
                Mcp::ToolArgument.new(name: :session, type: :session_state,
                                      summary: "Previously serialized creator session payload.", required: true)
              ]
            ),
            Mcp::ToolDefinition.new(
              name: :creator_session_write_plan,
              summary: "Build writer plan payload from a serialized creator session.",
              target: :optional_profile_or_environment,
              arguments: [
                Mcp::ToolArgument.new(name: :session, type: :session_state,
                                      summary: "Previously serialized creator session payload.", required: true)
              ]
            ),
            Mcp::ToolDefinition.new(
              name: :creator_session_write,
              summary: "Write scaffold files from a serialized creator session.",
              mutating: true,
              target: :optional_profile_or_environment,
              arguments: [
                Mcp::ToolArgument.new(name: :session, type: :session_state,
                                      summary: "Previously serialized creator session payload.", required: true)
              ]
            ),
            Mcp::ToolDefinition.new(
              name: :creator_workflow,
              summary: "Build a creator workflow payload.",
              target: :optional_profile_or_environment,
              arguments: creator_arguments(include_scope: true)
            ),
            Mcp::ToolDefinition.new(
              name: :creator_write_plan,
              summary: "Build a creator writer plan payload.",
              target: :optional_profile_or_environment,
              arguments: creator_arguments(include_scope: true, include_root: true, require_name: true,
                                           require_root: true)
            ),
            Mcp::ToolDefinition.new(
              name: :creator_write,
              summary: "Write a creator scaffold to disk.",
              mutating: true,
              target: :optional_profile_or_environment,
              arguments: creator_arguments(include_scope: true, include_root: true, require_name: true,
                                           require_root: true)
            )
          ].freeze
        end

        def tool_catalog
          tools.map(&:to_h)
        end

        def call(tool_name, target: nil, **arguments, &block)
          definition = tool_definition(tool_name)
          payload = dispatch(definition.name, target: target, **arguments, &block)
          Mcp::ToolResult.new(
            tool_name: definition.name,
            payload: payload,
            mutating: definition.mutating
          )
        end

        def tool_definition(tool_name)
          tools.find { |definition| definition.name == tool_name.to_sym } ||
            raise(ArgumentError, "unknown MCP tool #{tool_name.inspect}")
        end

        def dispatch(tool_name, target: nil, **arguments, &block)
          case tool_name.to_sym
          when :inspect_profile
            profile_from(target).then { |profile| DebugPack.profile_snapshot(profile).to_h }
          when :inspect_pack
            profile = profile_from(target)
            DebugPack.pack_snapshot(arguments.fetch(:pack), profile: profile).to_h
          when :audit_pack
            DebugPack.audit(arguments.fetch(:pack), profile: profile_from(target, optional: true)).to_h
          when :debug_report
            environment = environment_from(target)
            DebugPack.report(
              environment,
              inputs: arguments[:inputs],
              compiled_graph: arguments[:compiled_graph],
              &block
            ).to_h
          when :creator_wizard
            CreatorPack.wizard(
              name: arguments[:name],
              kind: arguments[:kind],
              namespace: arguments.fetch(:namespace, "MyCompany::IgniterPacks"),
              profile: arguments[:profile],
              capabilities: arguments[:capabilities],
              scope: arguments[:scope],
              root: arguments[:root],
              mode: arguments.fetch(:mode, :skip_existing),
              pack: arguments[:pack],
              target_profile: profile_from(target, optional: true)
            ).to_h
          when :creator_session_start
            creator_session_from(arguments, target: target).to_h
          when :creator_session_apply
            session = session_from(arguments.fetch(:session) { arguments.fetch("session") }, target: target)
            session.apply(**symbolize_keys(arguments.fetch(:updates) { arguments.fetch("updates") })).to_h
          when :creator_session_workflow
            session_from(arguments.fetch(:session) { arguments.fetch("session") }, target: target).workflow_payload
          when :creator_session_write_plan
            session_from(arguments.fetch(:session) { arguments.fetch("session") }, target: target).write_plan_payload
          when :creator_session_write
            session_from(arguments.fetch(:session) { arguments.fetch("session") }, target: target).write_payload
          when :creator_workflow
            CreatorPack.workflow(
              name: arguments.fetch(:name),
              kind: arguments[:kind],
              namespace: arguments.fetch(:namespace, "MyCompany::IgniterPacks"),
              profile: arguments[:profile],
              capabilities: arguments[:capabilities],
              scope: arguments.fetch(:scope, :monorepo_package),
              pack: arguments[:pack],
              target_profile: profile_from(target, optional: true)
            ).to_h
          when :creator_write_plan
            CreatorPack.writer(
              name: arguments.fetch(:name),
              kind: arguments[:kind],
              namespace: arguments.fetch(:namespace, "MyCompany::IgniterPacks"),
              profile: arguments[:profile],
              capabilities: arguments[:capabilities],
              scope: arguments.fetch(:scope, :monorepo_package),
              pack: arguments[:pack],
              target_profile: profile_from(target, optional: true),
              root: arguments.fetch(:root),
              mode: arguments.fetch(:mode, :skip_existing)
            ).plan.to_h
          when :creator_write
            CreatorPack.write(
              name: arguments.fetch(:name),
              kind: arguments[:kind],
              namespace: arguments.fetch(:namespace, "MyCompany::IgniterPacks"),
              profile: arguments[:profile],
              capabilities: arguments[:capabilities],
              scope: arguments.fetch(:scope, :monorepo_package),
              pack: arguments[:pack],
              target_profile: profile_from(target, optional: true),
              root: arguments.fetch(:root),
              mode: arguments.fetch(:mode, :skip_existing)
            ).to_h
          else
            raise ArgumentError, "unsupported MCP tool #{tool_name.inspect}"
          end
        end

        def profile_from(target, optional: false)
          profile =
            case target
            when nil
              nil
            else
              target.respond_to?(:profile) ? target.profile : target
            end

          return profile if optional || profile

          raise ArgumentError, "McpPack tool requires an environment or profile target"
        end

        def environment_from(target)
          return target if target.respond_to?(:profile) && target.respond_to?(:execute)

          raise ArgumentError, "McpPack debug_report requires an environment target"
        end

        def creator_arguments(include_scope: false, include_root: false, require_name: false, require_root: false)
          arguments = [
            Mcp::ToolArgument.new(name: :name, type: :string, summary: "Pack name without the trailing _pack suffix.",
                                  required: require_name),
            Mcp::ToolArgument.new(name: :kind, type: :symbol, summary: "Explicit pack kind when not inferred.",
                                  enum: %i[feature operational bundle]),
            Mcp::ToolArgument.new(name: :namespace, type: :string,
                                  summary: "Ruby namespace for generated pack constants.", default: "MyCompany::IgniterPacks"),
            Mcp::ToolArgument.new(name: :profile, type: :symbol, summary: "Named creator profile.",
                                  enum: CreatorPack.available_profiles),
            Mcp::ToolArgument.new(name: :capabilities, type: :symbol_array,
                                  summary: "Capabilities used to infer or refine the profile."),
            Mcp::ToolArgument.new(name: :pack, type: :pack_reference,
                                  summary: "Custom pack module for audit-aware creator flows."),
            Mcp::ToolArgument.new(name: :mode, type: :symbol, summary: "Writer behavior when files already exist.",
                                  default: :skip_existing, enum: %i[skip_existing overwrite])
          ]
          if include_scope
            arguments << Mcp::ToolArgument.new(name: :scope, type: :symbol, summary: "Target packaging scope.",
                                               required: false, enum: CreatorPack.available_scopes)
          end
          if include_root
            arguments << Mcp::ToolArgument.new(name: :root, type: :string,
                                               summary: "Filesystem root for generated files.", required: require_root)
          end
          if include_scope && require_root
            arguments.find { |argument| argument.name == :scope }&.tap do |argument|
              arguments[arguments.index(argument)] = Mcp::ToolArgument.new(
                name: :scope,
                type: :symbol,
                summary: "Target packaging scope.",
                required: true,
                enum: CreatorPack.available_scopes
              )
            end
          end
          arguments
        end

        def creator_session_from(arguments, target:)
          Mcp::CreatorSession.new(
            name: arguments[:name],
            kind: arguments[:kind],
            namespace: arguments.fetch(:namespace, "MyCompany::IgniterPacks"),
            profile: arguments[:profile],
            capabilities: arguments[:capabilities],
            scope: arguments[:scope],
            root: arguments[:root],
            mode: arguments.fetch(:mode, :skip_existing),
            pack: arguments[:pack],
            target_profile: profile_from(target, optional: true)
          )
        end

        def session_from(payload, target:)
          Mcp::CreatorSession.from_h(
            symbolize_keys(payload),
            target_profile: profile_from(target, optional: true)
          )
        end

        def symbolize_keys(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, nested), memo|
              memo[key.respond_to?(:to_sym) ? key.to_sym : key] = symbolize_keys(nested)
            end
          when Array
            value.map { |item| symbolize_keys(item) }
          else
            value
          end
        end
      end
    end
  end
end
