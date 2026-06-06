# frozen_string_literal: true

require "igniter/contracts"
require_relative "contracts/aggregate_pack"
require_relative "contracts/audit_pack"
require_relative "contracts/branch_pack"
require_relative "contracts/capabilities_pack"
require_relative "contracts/collection_pack"
require_relative "contracts/commerce_pack"
require_relative "contracts/compose_pack"
require_relative "contracts/content_addressing_pack"
require_relative "contracts/creator_pack"
require_relative "contracts/dataflow_pack"
require_relative "contracts/debug_pack"
require_relative "contracts/differential_pack"
require_relative "contracts/execution_report_pack"
require_relative "contracts/incremental_pack"
require_relative "contracts/invariants_pack"
require_relative "contracts/journal_pack"
require_relative "contracts/language/formula_pack"
require_relative "contracts/language/piecewise_pack"
require_relative "contracts/language/scale_pack"
require_relative "contracts/lookup_pack"
require_relative "contracts/mcp_pack"
require_relative "contracts/provenance_pack"
require_relative "contracts/reactive_pack"
require_relative "contracts/saga_pack"

module Igniter
  module Extensions
    module Contracts
      DEFAULT_PACKS = [
        ExecutionReportPack,
        LookupPack
      ].freeze

      AVAILABLE_PACKS = (
        DEFAULT_PACKS +
        [AggregatePack, AuditPack, BranchPack, CapabilitiesPack, CollectionPack, CommercePack, ComposePack,
         ContentAddressingPack, CreatorPack, DataflowPack, DebugPack, DifferentialPack, IncrementalPack,
         InvariantsPack, JournalPack, Language::FormulaPack, Language::PiecewisePack, Language::ScalePack,
         McpPack, ProvenancePack, ReactivePack, SagaPack]
      ).freeze

      PRESETS = {
        default: DEFAULT_PACKS,
        commerce: [ExecutionReportPack, CommercePack]
      }.freeze

      class << self
        def default_packs
          DEFAULT_PACKS
        end

        def available_packs
          AVAILABLE_PACKS
        end

        def presets
          PRESETS
        end

        def packs_for(name)
          presets.fetch(name.to_sym)
        rescue KeyError
          raise ArgumentError, "unknown contracts preset #{name}"
        end

        def build_profile(*packs)
          Igniter::Contracts.build_profile(*normalize_packs(packs))
        end

        def with(*packs)
          Igniter::Contracts.with(*normalize_packs(packs))
        end

        def build_preset_profile(name)
          build_profile(*packs_for(name))
        end

        def with_preset(name)
          with(*packs_for(name))
        end

        def lineage(result, output_name)
          ProvenancePack.lineage(result, output_name)
        end

        def explain(result, output_name)
          ProvenancePack.explain(result, output_name)
        end

        def build_compensations(&block)
          SagaPack.build(&block)
        end

        def run_saga(environment, inputs:, compensations:, compiled_graph: nil, &block)
          SagaPack.run(
            environment,
            inputs: inputs,
            compensations: compensations,
            compiled_graph: compiled_graph,
            &block
          )
        end

        def build_incremental_session(environment, compiled_graph: nil, &block)
          IncrementalPack.session(environment, compiled_graph: compiled_graph, &block)
        end

        def build_dataflow_session(environment, source:, key:, window: nil, context: [], &block)
          DataflowPack.session(
            environment,
            source: source,
            key: key,
            window: window,
            context: context,
            &block
          )
        end

        def compare_differential(
          inputs:,
          primary_environment: nil,
          primary_compiled_graph: nil,
          primary_result: nil,
          candidate_environment: nil,
          candidate_compiled_graph: nil,
          candidate_result: nil,
          tolerance: nil,
          primary_name: "primary",
          candidate_name: "candidate"
        )
          DifferentialPack.compare(
            inputs: inputs,
            primary_environment: primary_environment,
            primary_compiled_graph: primary_compiled_graph,
            primary_result: primary_result,
            candidate_environment: candidate_environment,
            candidate_compiled_graph: candidate_compiled_graph,
            candidate_result: candidate_result,
            tolerance: tolerance,
            primary_name: primary_name,
            candidate_name: candidate_name
          )
        end

        def shadow_differential(**arguments)
          DifferentialPack.shadow(**arguments)
        end

        def audit_snapshot(result)
          AuditPack.snapshot(result)
        end

        def audit_report(environment, inputs: nil, compiled_graph: nil, &block)
          AuditPack.report(environment, inputs: inputs, compiled_graph: compiled_graph, &block)
        end

        def build_reactions(&block)
          ReactivePack.build(&block)
        end

        def dispatch_reactive(target, reactions:)
          ReactivePack.dispatch(target, reactions: reactions)
        end

        def run_reactive(environment, inputs:, reactions:, compiled_graph: nil, &block)
          ReactivePack.run(environment, inputs: inputs, reactions: reactions, compiled_graph: compiled_graph, &block)
        end

        def run_incremental_reactive(session, inputs:, reactions:)
          ReactivePack.run_incremental(session, inputs: inputs, reactions: reactions)
        end

        def build_invariants(&block)
          InvariantsPack.build(&block)
        end

        def check_invariants(target, invariants:)
          InvariantsPack.check(target, invariants: invariants)
        end

        def validate_invariants!(target, invariants:)
          InvariantsPack.validate!(target, invariants: invariants)
        end

        def run_invariants(environment, inputs:, invariants:, compiled_graph: nil, &block)
          InvariantsPack.run(environment, inputs: inputs, invariants: invariants, compiled_graph: compiled_graph,
                             &block)
        end

        def verify_invariant_cases(environment, cases:, invariants:, compiled_graph: nil, &block)
          InvariantsPack.verify_cases(environment,
                                      cases: cases, invariants: invariants, compiled_graph: compiled_graph, &block)
        end

        def declare_capabilities(*capabilities, callable: nil, &block)
          CapabilitiesPack.declare(*capabilities, callable: callable, &block)
        end

        def pure_callable(callable: nil, &block)
          CapabilitiesPack.pure(callable: callable, &block)
        end

        def capability_policy(denied: [], required: [], on_undeclared: :ignore)
          CapabilitiesPack.policy(denied: denied, required: required, on_undeclared: on_undeclared)
        end

        def required_capabilities(compiled_graph)
          CapabilitiesPack.required_capabilities(compiled_graph)
        end

        def capabilities_for(compiled_graph, node_name)
          CapabilitiesPack.capabilities_for(compiled_graph, node_name)
        end

        def profile_capabilities(profile_or_environment)
          profile = profile_or_environment.respond_to?(:profile) ? profile_or_environment.profile : profile_or_environment
          CapabilitiesPack.profile_capabilities(profile)
        end

        def capability_report(compiled_graph, profile: nil, policy: nil)
          CapabilitiesPack.report(compiled_graph, profile: profile, policy: policy)
        end

        def check_capabilities!(compiled_graph, policy:, profile: nil)
          CapabilitiesPack.check!(compiled_graph, profile: profile, policy: policy)
        end

        def content_addressed(callable: nil, fingerprint: nil, capabilities: [:pure],
                              cache: ContentAddressingPack.cache, &block)
          ContentAddressingPack.content_addressed(
            callable: callable,
            fingerprint: fingerprint,
            capabilities: capabilities,
            cache: cache,
            &block
          )
        end

        def pure_content_callable(callable: nil, fingerprint: nil, cache: ContentAddressingPack.cache, &block)
          ContentAddressingPack.pure(callable: callable, fingerprint: fingerprint, cache: cache, &block)
        end

        def content_key(inputs:, fingerprint: nil, callable: nil)
          ContentAddressingPack.content_key(fingerprint: fingerprint, callable: callable, inputs: inputs)
        end

        def content_cache
          ContentAddressingPack.cache
        end

        def reset_content_cache!
          ContentAddressingPack.reset_cache!
        end

        def debug_profile(target)
          profile = target.respond_to?(:profile) ? target.profile : target
          DebugPack.profile_snapshot(profile)
        end

        def debug_pack(pack_or_name, target)
          profile = target.respond_to?(:profile) ? target.profile : target
          DebugPack.pack_snapshot(pack_or_name, profile: profile)
        end

        def audit_pack(pack, target = nil)
          profile =
            case target
            when nil
              nil
            else
              target.respond_to?(:profile) ? target.profile : target
            end

          DebugPack.audit(pack, profile: profile)
        end

        def creator_profiles
          CreatorPack.available_profiles
        end

        def creator_scopes
          CreatorPack.available_scopes
        end

        def scaffold_pack(name:, kind: nil, namespace: "MyCompany::IgniterPacks", profile: nil, capabilities: nil,
                          scope: :monorepo_package)
          CreatorPack.scaffold(
            name: name,
            kind: kind,
            namespace: namespace,
            profile: profile,
            capabilities: capabilities,
            scope: scope
          )
        end

        def creator_report(name:, kind: nil, namespace: "MyCompany::IgniterPacks", profile: nil, capabilities: nil,
                           scope: :monorepo_package, pack: nil, target: nil)
          runtime_profile =
            case target
            when nil
              nil
            else
              target.respond_to?(:profile) ? target.profile : target
            end

          CreatorPack.report(
            name: name,
            kind: kind,
            namespace: namespace,
            profile: profile,
            capabilities: capabilities,
            scope: scope,
            pack: pack,
            target_profile: runtime_profile
          )
        end

        def creator_workflow(name:, kind: nil, namespace: "MyCompany::IgniterPacks", profile: nil, capabilities: nil,
                             scope: :monorepo_package, pack: nil, target: nil)
          runtime_profile =
            case target
            when nil
              nil
            else
              target.respond_to?(:profile) ? target.profile : target
            end

          CreatorPack.workflow(
            name: name,
            kind: kind,
            namespace: namespace,
            profile: profile,
            capabilities: capabilities,
            scope: scope,
            pack: pack,
            target_profile: runtime_profile
          )
        end

        def creator_wizard(name: nil, kind: nil, namespace: "MyCompany::IgniterPacks", profile: nil, capabilities: nil,
                           scope: nil, root: nil, mode: :skip_existing, pack: nil, target: nil)
          runtime_profile =
            case target
            when nil
              nil
            else
              target.respond_to?(:profile) ? target.profile : target
            end

          CreatorPack.wizard(
            name: name,
            kind: kind,
            namespace: namespace,
            profile: profile,
            capabilities: capabilities,
            scope: scope,
            root: root,
            mode: mode,
            pack: pack,
            target_profile: runtime_profile
          )
        end

        def creator_writer(name:, root:, kind: nil, namespace: "MyCompany::IgniterPacks", profile: nil, capabilities: nil,
                           scope: :monorepo_package, pack: nil, target: nil, mode: :skip_existing)
          runtime_profile =
            case target
            when nil
              nil
            else
              target.respond_to?(:profile) ? target.profile : target
            end

          CreatorPack.writer(
            name: name,
            kind: kind,
            namespace: namespace,
            profile: profile,
            capabilities: capabilities,
            scope: scope,
            pack: pack,
            target_profile: runtime_profile,
            root: root,
            mode: mode
          )
        end

        def write_pack_scaffold(name:, root:, kind: nil, namespace: "MyCompany::IgniterPacks", profile: nil,
                                capabilities: nil, scope: :monorepo_package, pack: nil, target: nil, mode: :skip_existing)
          runtime_profile =
            case target
            when nil
              nil
            else
              target.respond_to?(:profile) ? target.profile : target
            end

          CreatorPack.write(
            name: name,
            kind: kind,
            namespace: namespace,
            profile: profile,
            capabilities: capabilities,
            scope: scope,
            pack: pack,
            target_profile: runtime_profile,
            root: root,
            mode: mode
          )
        end

        def mcp_tools
          McpPack.tool_catalog
        end

        def mcp_call(tool_name, target: nil, **arguments, &block)
          McpPack.call(tool_name, target: target, **arguments, &block)
        end

        def mcp_creator_session(target: nil, **arguments)
          mcp_call(:creator_session_start, target: target, **arguments)
        end

        def debug_snapshot(result, profile:)
          DebugPack.snapshot(result, profile: profile)
        end

        def debug_report(environment, inputs: nil, compiled_graph: nil, &block)
          DebugPack.report(environment, inputs: inputs, compiled_graph: compiled_graph, &block)
        end

        private

        def normalize_packs(packs)
          normalized = packs.flatten.compact
          normalized.empty? ? default_packs : normalized
        end
      end
    end
  end
end
