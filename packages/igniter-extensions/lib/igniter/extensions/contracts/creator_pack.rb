# frozen_string_literal: true

require_relative "creator/profile"
require_relative "creator/scaffold"
require_relative "creator/scope"
require_relative "creator/report"
require_relative "creator/workflow"
require_relative "creator/wizard"

module Igniter
  module Extensions
    module Contracts
      module CreatorPack
        module_function

        def manifest
          Igniter::Contracts::PackManifest.new(
            name: :extensions_creator,
            requires_packs: [DebugPack],
            metadata: { category: :developer }
          )
        end

        def install_into(kernel)
          kernel
        end

        def available_profiles
          Creator::Profile.available
        end

        def available_scopes
          Creator::Scope.available
        end

        def scaffold(name:, kind: nil, namespace: "MyCompany::IgniterPacks", profile: nil, capabilities: nil,
                     scope: :monorepo_package)
          authoring_profile = Creator::Profile.build(profile: profile, kind: kind, capabilities: capabilities)
          target_scope = Creator::Scope.build(scope)
          Creator::Scaffold.new(
            name: name,
            kind: authoring_profile.kind,
            namespace: namespace,
            profile: authoring_profile,
            scope: target_scope
          )
        end

        def report(name:, kind: nil, namespace: "MyCompany::IgniterPacks", profile: nil, capabilities: nil,
                   scope: :monorepo_package, pack: nil, target_profile: nil)
          generated = scaffold(
            name: name,
            kind: kind,
            namespace: namespace,
            profile: profile,
            capabilities: capabilities,
            scope: scope
          )
          audit = pack ? DebugPack.audit(pack, profile: target_profile) : nil

          Creator::Report.new(scaffold: generated, audit: audit)
        end

        def workflow(name:, kind: nil, namespace: "MyCompany::IgniterPacks", profile: nil, capabilities: nil,
                     scope: :monorepo_package, pack: nil, target_profile: nil)
          Creator::Workflow.new(
            report: report(
              name: name,
              kind: kind,
              namespace: namespace,
              profile: profile,
              capabilities: capabilities,
              scope: scope,
              pack: pack,
              target_profile: target_profile
            )
          )
        end

        def wizard(name: nil, kind: nil, namespace: "MyCompany::IgniterPacks", profile: nil, capabilities: nil,
                   scope: nil, root: nil, mode: :skip_existing, pack: nil, target_profile: nil)
          Creator::Wizard.new(
            name: name,
            kind: kind,
            namespace: namespace,
            profile: profile,
            capabilities: capabilities,
            scope: scope,
            root: root,
            mode: mode,
            pack: pack,
            target_profile: target_profile
          )
        end

        def writer(name:, root:, kind: nil, namespace: "MyCompany::IgniterPacks", profile: nil, capabilities: nil,
                   scope: :monorepo_package, pack: nil, target_profile: nil, mode: :skip_existing)
          workflow(
            name: name,
            kind: kind,
            namespace: namespace,
            profile: profile,
            capabilities: capabilities,
            scope: scope,
            pack: pack,
            target_profile: target_profile
          ).writer(root: root, mode: mode)
        end

        def write(name:, root:, kind: nil, namespace: "MyCompany::IgniterPacks", profile: nil, capabilities: nil,
                  scope: :monorepo_package, pack: nil, target_profile: nil, mode: :skip_existing)
          writer(
            name: name,
            kind: kind,
            namespace: namespace,
            profile: profile,
            capabilities: capabilities,
            scope: scope,
            pack: pack,
            target_profile: target_profile,
            root: root,
            mode: mode
          ).write
        end
      end
    end
  end
end
