# frozen_string_literal: true

require "igniter/contracts"
require "igniter/extensions/contracts"
require "igniter-ai"
require "igniter-agents"

require_relative "application/config"
require_relative "application/config_builder"
require_relative "application/ai_provider_definition"
require_relative "application/ai_builder"
require_relative "application/ai_registry"
require_relative "application/agent_definition"
require_relative "application/agents_builder"
require_relative "application/agent_runtime"
require_relative "application/agent_registry"
require_relative "application/missing_credential_error"
require_relative "application/credential_definition"
require_relative "application/credential_store"
require_relative "application/application_layout"
require_relative "application/application_manifest"
require_relative "application/application_structure_entry"
require_relative "application/application_structure_plan"
require_relative "application/capsule_export"
require_relative "application/capsule_import"
require_relative "application/feature_slice"
require_relative "application/feature_slice_report"
require_relative "application/application_blueprint"
require_relative "application/flow_event"
require_relative "application/pending_input"
require_relative "application/pending_action"
require_relative "application/artifact_reference"
require_relative "application/flow_declaration"
require_relative "application/application_capsule_report"
require_relative "application/capsule_builder"
require_relative "application/application_composition_report"
require_relative "application/mount_intent"
require_relative "application/application_assembly_plan"
require_relative "application/application_handoff_manifest"
require_relative "application/application_transfer_inventory"
require_relative "application/application_transfer_readiness"
require_relative "application/application_transfer_bundle_plan"
require_relative "application/application_transfer_bundle_artifact"
require_relative "application/application_transfer_bundle_verification"
require_relative "application/application_transfer_intake_plan"
require_relative "application/application_transfer_apply_plan"
require_relative "application/application_transfer_apply_result"
require_relative "application/application_transfer_applied_verification"
require_relative "application/application_transfer_receipt"
require_relative "application/installed_capsule_entry"
require_relative "application/file_backed_installed_capsule_registry"
require_relative "application/application_host_activation_readiness"
require_relative "application/application_host_activation_plan"
require_relative "application/application_host_activation_plan_verification"
require_relative "application/application_host_activation_dry_run_result"
require_relative "application/application_host_activation_commit_readiness"
require_relative "application/application_host_activation_operation_digest"
require_relative "application/file_backed_host_activation_ledger_adapter"
require_relative "application/application_host_activation_ledger_commit"
require_relative "application/application_host_activation_ledger_verification"
require_relative "application/application_host_activation_receipt"
require_relative "application/flow_session_snapshot"
require_relative "application/application_load_path"
require_relative "application/application_load_report"
require_relative "application/provider"
require_relative "application/provider_registration"
require_relative "application/provider_lifecycle_result"
require_relative "application/provider_lifecycle_report"
require_relative "application/service_definition"
require_relative "application/interface"
require_relative "application/service_registry"
require_relative "application/contract_registry"
require_relative "application/mount_registration"
require_relative "application/transport_request"
require_relative "application/transport_response"
require_relative "application/compose_transport_adapter"
require_relative "application/collection_transport_adapter"
require_relative "application/compose_invoker"
require_relative "application/collection_invoker"
require_relative "application/session_entry"
require_relative "application/memory_session_store"
require_relative "application/boot_phase"
require_relative "application/seam_lifecycle_result"
require_relative "application/lifecycle_plan_step"
require_relative "application/plan_executor"
require_relative "application/embedded_host"
require_relative "application/manual_loader"
require_relative "application/manual_scheduler"
require_relative "application/kernel"
require_relative "application/profile"
require_relative "application/snapshot"
require_relative "application/boot_plan"
require_relative "application/boot_report"
require_relative "application/shutdown_plan"
require_relative "application/shutdown_report"
require_relative "application/environment"
require_relative "application/rack_host"

module Igniter
  module Application
    class << self
      def build_kernel(*packs)
        kernel = Kernel.new
        packs.flatten.compact.each { |pack| kernel.install_pack(pack) }
        kernel
      end

      def build_profile(*packs)
        build_kernel(*packs).finalize
      end

      def with(*packs)
        Environment.new(profile: build_profile(*packs))
      end

      def rack_app(name, root:, env: :development, metadata: {}, &block)
        RackHost.build(name, root: root, env: env, metadata: metadata, &block)
      end

      def blueprint(...)
        ApplicationBlueprint.new(...)
      end

      def capsule(name, root:, env: :development, &block)
        CapsuleBuilder.build(name, root: root, env: env, &block)
      end

      def compose_capsules(*capsules, host_exports: [], host_capabilities: [], metadata: {})
        ApplicationCompositionReport.inspect(
          capsules: capsules.flatten,
          host_exports: host_exports,
          host_capabilities: host_capabilities,
          metadata: metadata
        )
      end

      def assemble_capsules(*capsules, host_exports: [], host_capabilities: [], mount_intents: [],
                            surface_metadata: [], metadata: {})
        ApplicationAssemblyPlan.build(
          capsules: capsules.flatten,
          host_exports: host_exports,
          host_capabilities: host_capabilities,
          mount_intents: mount_intents,
          surface_metadata: surface_metadata,
          metadata: metadata
        )
      end

      def handoff_manifest(subject:, capsules: [], assembly_plan: nil, host_exports: [], host_capabilities: [],
                           mount_intents: [], surface_metadata: [], metadata: {})
        ApplicationHandoffManifest.build(
          subject: subject,
          capsules: capsules,
          assembly_plan: assembly_plan,
          host_exports: host_exports,
          host_capabilities: host_capabilities,
          mount_intents: mount_intents,
          surface_metadata: surface_metadata,
          metadata: metadata
        )
      end

      def transfer_inventory(*capsules, surface_metadata: [], enumerate_files: true, metadata: {})
        ApplicationTransferInventory.build(
          capsules: capsules.flatten,
          surface_metadata: surface_metadata,
          enumerate_files: enumerate_files,
          metadata: metadata
        )
      end

      def transfer_readiness(*capsules, handoff_manifest: nil, transfer_inventory: nil, subject: :capsule_transfer,
                             host_exports: [], host_capabilities: [], mount_intents: [], surface_metadata: [],
                             enumerate_files: true, policy: {}, metadata: {})
        ApplicationTransferReadiness.build(
          handoff_manifest: handoff_manifest,
          transfer_inventory: transfer_inventory,
          capsules: capsules.flatten,
          subject: subject,
          host_exports: host_exports,
          host_capabilities: host_capabilities,
          mount_intents: mount_intents,
          surface_metadata: surface_metadata,
          enumerate_files: enumerate_files,
          policy: policy,
          metadata: metadata
        )
      end

      def transfer_bundle_plan(*capsules, transfer_readiness: nil, handoff_manifest: nil, transfer_inventory: nil,
                               subject: :capsule_transfer, host_exports: [], host_capabilities: [],
                               mount_intents: [], surface_metadata: [], enumerate_files: true,
                               readiness_policy: {}, policy: {}, metadata: {})
        ApplicationTransferBundlePlan.build(
          transfer_readiness: transfer_readiness,
          handoff_manifest: handoff_manifest,
          transfer_inventory: transfer_inventory,
          capsules: capsules.flatten,
          subject: subject,
          host_exports: host_exports,
          host_capabilities: host_capabilities,
          mount_intents: mount_intents,
          surface_metadata: surface_metadata,
          enumerate_files: enumerate_files,
          readiness_policy: readiness_policy,
          policy: policy,
          metadata: metadata
        )
      end

      def write_transfer_bundle(plan, output:, allow_not_ready: false, create_parent: false, metadata: {})
        ApplicationTransferBundleArtifact.write(
          plan,
          output: output,
          allow_not_ready: allow_not_ready,
          create_parent: create_parent,
          metadata: metadata
        )
      end

      def verify_transfer_bundle(path, metadata: {})
        ApplicationTransferBundleVerification.verify(path, metadata: metadata)
      end

      def transfer_intake_plan(verification_or_path, destination_root:, metadata: {})
        ApplicationTransferIntakePlan.build(
          verification_or_path,
          destination_root: destination_root,
          metadata: metadata
        )
      end

      def transfer_apply_plan(intake_plan, metadata: {})
        ApplicationTransferApplyPlan.build(intake_plan, metadata: metadata)
      end

      def apply_transfer_plan(apply_plan, commit: false, metadata: {})
        ApplicationTransferApplyResult.apply(
          apply_plan,
          commit: commit,
          metadata: metadata
        )
      end

      def verify_applied_transfer(apply_result, apply_plan: nil, metadata: {})
        ApplicationTransferAppliedVerification.verify(
          apply_result,
          apply_plan: apply_plan,
          metadata: metadata
        )
      end

      def transfer_receipt(applied_verification, apply_result: nil, apply_plan: nil, metadata: {})
        ApplicationTransferReceipt.build(
          applied_verification,
          apply_result: apply_result,
          apply_plan: apply_plan,
          metadata: metadata
        )
      end

      def file_backed_installed_capsule_registry(root:)
        FileBackedInstalledCapsuleRegistry.build(root: root)
      end

      def record_installed_capsule(name, receipt:, registry:, source: nil, version: nil, metadata: {})
        registry.record(
          name,
          receipt: receipt,
          source: source,
          version: version,
          metadata: metadata
        )
      end

      def host_activation_readiness(transfer_receipt, handoff_manifest: nil, host_exports: [], host_capabilities: [],
                                    manual_actions: [], load_paths: [], providers: [], contracts: [], lifecycle: {},
                                    mount_decisions: [], surface_metadata: [], metadata: {})
        ApplicationHostActivationReadiness.build(
          transfer_receipt,
          handoff_manifest: handoff_manifest,
          host_exports: host_exports,
          host_capabilities: host_capabilities,
          manual_actions: manual_actions,
          load_paths: load_paths,
          providers: providers,
          contracts: contracts,
          lifecycle: lifecycle,
          mount_decisions: mount_decisions,
          surface_metadata: surface_metadata,
          metadata: metadata
        )
      end

      def host_activation_plan(readiness, metadata: {})
        ApplicationHostActivationPlan.build(readiness, metadata: metadata)
      end

      def verify_host_activation_plan(plan, metadata: {})
        ApplicationHostActivationPlanVerification.verify(plan, metadata: metadata)
      end

      def dry_run_host_activation(verification, host_target: nil, metadata: {})
        ApplicationHostActivationDryRunResult.dry_run(
          verification,
          host_target: host_target,
          metadata: metadata
        )
      end

      def host_activation_commit_readiness(dry_run, provided_adapters: [], metadata: {})
        ApplicationHostActivationCommitReadiness.build(
          dry_run,
          provided_adapters: provided_adapters,
          metadata: metadata
        )
      end

      def host_activation_operation_digest(dry_run)
        ApplicationHostActivationOperationDigest.compute(dry_run)
      end

      def file_backed_host_activation_ledger_adapter(root:, name: :file_backed_host_activation_ledger)
        FileBackedHostActivationLedgerAdapter.build(root: root, name: name)
      end

      def host_activation_ledger_commit(evidence_packet, adapter:, metadata: {})
        ApplicationHostActivationLedgerCommit.commit(
          evidence_packet,
          adapter: adapter,
          metadata: metadata
        )
      end

      def verify_host_activation_ledger(evidence_packet, commit_result:, adapter:, metadata: {})
        ApplicationHostActivationLedgerVerification.verify(
          evidence_packet,
          commit_result: commit_result,
          adapter: adapter,
          metadata: metadata
        )
      end

      def host_activation_receipt(verification, evidence_packet:, commit_result:, metadata: {})
        ApplicationHostActivationReceipt.build(
          verification,
          evidence_packet: evidence_packet,
          commit_result: commit_result,
          metadata: metadata
        )
      end
    end
  end
end
