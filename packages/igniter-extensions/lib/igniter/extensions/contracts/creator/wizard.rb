# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Creator
        class Wizard
          PROFILE_EXAMPLES = {
            feature_node: ["examples/contracts/build_your_own_pack.rb"],
            diagnostic_bundle: ["examples/contracts/debug.rb", "examples/contracts/debug_pack_authoring.rb"],
            operational_adapter: ["examples/contracts/build_effect_executor_pack.rb", "examples/contracts/journal.rb"],
            bundle_pack: ["examples/contracts/compose_your_own_packs.rb", "examples/contracts/commerce.rb"]
          }.freeze

          attr_reader :name, :kind, :namespace, :profile, :capabilities, :scope, :root, :mode, :pack, :target_profile

          def initialize(name: nil, kind: nil, namespace: "MyCompany::IgniterPacks", profile: nil, capabilities: nil,
                         scope: nil, root: nil, mode: :skip_existing, pack: nil, target_profile: nil)
            @name = normalize_name(name)
            @kind = kind&.to_sym
            @namespace = normalize_namespace(namespace)
            @profile = profile&.to_sym
            @capabilities = Array(capabilities).map(&:to_sym).uniq.freeze
            @scope = scope&.to_sym
            @root = root&.to_s
            @mode = mode.to_sym
            @pack = pack
            @target_profile = target_profile
            freeze
          end

          def apply(**updates)
            self.class.new(
              name: updates.fetch(:name, name),
              kind: updates.fetch(:kind, kind),
              namespace: updates.fetch(:namespace, namespace),
              profile: updates.fetch(:profile, profile),
              capabilities: updates.fetch(:capabilities, capabilities),
              scope: updates.fetch(:scope, scope),
              root: updates.fetch(:root, root),
              mode: updates.fetch(:mode, mode),
              pack: updates.fetch(:pack, pack),
              target_profile: updates.fetch(:target_profile, target_profile)
            )
          end

          def authoring_profile
            return nil unless profile || kind || !capabilities.empty?

            Profile.build(
              profile: profile,
              kind: kind,
              capabilities: capabilities
            )
          end

          def target_scope
            return nil unless scope

            Scope.build(scope)
          end

          def ready_for_workflow?
            !name.nil? && !authoring_profile.nil? && !target_scope.nil?
          end

          def ready_for_writer?
            ready_for_workflow? && !effective_root.nil?
          end

          def effective_root
            return root unless root.nil? || root.empty?
            return nil unless scope

            suggested_root
          end

          def suggested_root
            case scope
            when :standalone_gem
              name ? "./#{name}" : "./my_pack"
            when :app_local, :monorepo_package
              "."
            end
          end

          def pending_decisions
            decisions = []
            unless name
              decisions << {
                key: :name,
                prompt: "Choose a short pack name",
                options: [],
                hints: ["pick the public noun you want pack users to reach for"]
              }
            end

            unless authoring_profile
              decisions << {
                key: :profile,
                prompt: "Choose an authoring profile or provide capabilities",
                options: profile_options,
                hints: ["feature packs add graph semantics; operational packs add effect/executor behavior; bundles compose packs without semantic mutation"]
              }
            end

            unless target_scope
              decisions << {
                key: :scope,
                prompt: "Choose the target scope for the pack",
                options: scope_options,
                hints: branching_hints
              }
            end

            if ready_for_workflow? && root.nil?
              decisions << {
                key: :root,
                prompt: "Choose the filesystem root for generated files",
                options: [suggested_root].compact,
                hints: ["default root follows the chosen scope; override it only if the host repo layout needs it"]
              }
            end

            decisions
          end

          def current_decision
            pending_decisions.first
          end

          def recommended_packs
            return { runtime: [], development: [] } unless authoring_profile

            {
              runtime: authoring_profile.runtime_dependency_hints,
              development: authoring_profile.development_dependency_hints
            }
          end

          def recommended_examples
            return [] unless authoring_profile

            PROFILE_EXAMPLES.fetch(authoring_profile.name, PROFILE_EXAMPLES.fetch(fallback_profile_name, []))
          end

          def branching_hints
            return [] unless authoring_profile

            hints = []
            case authoring_profile.kind
            when :operational
              hints << "operational adapters usually want dev-time help from Igniter::Extensions::Contracts::JournalPack"
              hints << "prefer standalone_gem when the adapter will be reused across hosts"
            when :bundle
              if authoring_profile.capability?(:diagnostic)
                hints << "diagnostic bundles usually compose Igniter::Extensions::Contracts::ExecutionReportPack and Igniter::Extensions::Contracts::ProvenancePack"
                hints << "keep DebugPack as a development helper unless the bundle truly needs a runtime-facing debug surface"
              else
                hints << "bundle packs should stay thin and explicit about which packs they compose"
              end
            when :feature
              hints << "feature node packs often start app-local before being promoted into a monorepo package or gem"
            end

            hints.concat(authoring_profile.development_hints)
            hints.uniq
          end

          def workflow
            unless ready_for_workflow?
              raise ArgumentError, "creator wizard is missing decisions: #{pending_decisions.map do |decision|
                decision.fetch(:key)
              end.join(", ")}"
            end

            CreatorPack.workflow(
              name: name,
              kind: kind,
              namespace: namespace,
              profile: profile,
              capabilities: capabilities,
              scope: scope,
              pack: pack,
              target_profile: target_profile
            )
          end

          def writer
            raise ArgumentError, "creator wizard needs a root before writing scaffold files" unless ready_for_writer?

            workflow.writer(root: effective_root, mode: mode)
          end

          def to_h
            {
              name: name,
              kind: kind,
              namespace: namespace,
              profile: profile,
              capabilities: capabilities,
              scope: scope,
              root: root,
              suggested_root: suggested_root,
              effective_root: effective_root,
              mode: mode,
              ready_for_workflow: ready_for_workflow?,
              ready_for_writer: ready_for_writer?,
              authoring_profile: authoring_profile&.to_h,
              target_scope: target_scope&.to_h,
              recommended_packs: recommended_packs,
              recommended_examples: recommended_examples,
              branching_hints: branching_hints,
              pending_decisions: pending_decisions
            }
          end

          private

          def fallback_profile_name
            case authoring_profile&.kind
            when :operational
              :operational_adapter
            when :bundle
              authoring_profile&.capability?(:diagnostic) ? :diagnostic_bundle : :bundle_pack
            else
              :feature_node
            end
          end

          def profile_options
            Profile.available.map do |available_profile|
              built = Profile.build(profile: available_profile)
              {
                key: available_profile,
                kind: built.kind,
                summary: built.summary,
                capabilities: built.capabilities
              }
            end
          end

          def scope_options
            Scope.available.map do |available_scope|
              built = Scope.build(available_scope)
              {
                key: available_scope,
                root: built.root,
                summary: built.packaging_hints.first
              }
            end
          end

          def normalize_name(value)
            return nil if value.nil?

            normalized = value.to_s.strip.gsub(/_pack\z/, "").downcase
            normalized.empty? ? nil : normalized
          end

          def normalize_namespace(value)
            normalized = value.to_s.strip
            normalized.empty? ? "MyCompany::IgniterPacks" : normalized
          end
        end
      end
    end
  end
end
