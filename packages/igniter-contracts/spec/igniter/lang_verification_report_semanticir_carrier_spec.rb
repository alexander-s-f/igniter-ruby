# frozen_string_literal: true

require_relative "../spec_helper"
require "igniter/lang"

RSpec.describe "SemanticIR VerificationReport metadata carriers" do
  let(:redaction_policy) do
    {
      profile: "compiler_proof_public_metadata_v0",
      raw_ref_export: false,
      hash_source_refs: true,
      redacted_ref_kinds: %w[source_path workspace_path host_path agent_ref runtime_ref]
    }
  end

  def build_report(metadata)
    Igniter::Lang::VerificationReport.new(
      profile_fingerprint: "profile:polymorphic-add",
      operations: [],
      metadata: metadata
    )
  end

  it "carries SemanticIR compiler-pipeline proof profiles as opaque custom metadata" do
    report = build_report(
      redaction_policy: redaction_policy,
      custom_sections: {
        semanticir_verification_profiles: [
          {
            profile: "semanticir_artifact_profile_v0",
            profile_kind: "SemanticIRArtifactProfile",
            artifact_ref: "semantic_ir/polymorphic_add@v0",
            artifact_hash: "sha256:canonical-semantic-ir-json",
            source_program_ref: "source/polymorphic_add.ig",
            compiled_program_ref: "igapp/polymorphic_add@v0",
            semanticir_invariants: {
              no_type_variables: true,
              no_unresolved_overloads: true,
              no_unresolved_trait_calls: true,
              no_generic_contractir: true
            },
            evidence_refs: ["proof/polymorphic_add_semanticir_emission"],
            report_only: true,
            runtime_enforced: false
          },
          {
            profile: "classifier_diagnostic_profile_v0",
            profile_kind: "ClassifierDiagnosticProfile",
            stage: "classifier",
            status: "passed_with_negative",
            accepted_contract_refs: ["Add[Integer]", "Add[Float]"],
            rejected_contract_refs: ["Add[String]"],
            evidence_refs: ["proof/polymorphic_add_classifier"],
            report_only: true,
            runtime_enforced: false
          },
          {
            profile: "typecheck_diagnostic_profile_v0",
            profile_kind: "TypecheckDiagnosticProfile",
            stage: "typecheck",
            status: "accepted",
            typed_contract_refs: ["Add[Integer]", "Add[Float]"],
            evidence_refs: ["typed_program/polymorphic_add/classifier-proof@v0"],
            report_only: true,
            runtime_enforced: false
          },
          {
            profile: "oof_finding_profile_v0",
            profile_kind: "OOFFindingProfile",
            stage: "typecheck",
            oof_code: "OOF-TY1",
            severity: "error",
            decision: "rejected_before_semanticir",
            subject_ref: "Add[String]",
            semanticir_emitted: false,
            runtime_rejection_required: false,
            evidence_refs: ["proof/polymorphic_add_classifier"],
            report_only: true,
            runtime_enforced: false
          },
          {
            profile: "runtime_proof_receipt_profile_v0",
            profile_kind: "RuntimeProofReceiptProfile",
            receipt_ref: "runtime_proof/polymorphic_add/load-evaluate@v0",
            runtime_ref: "redacted:runtime/synthetic-fixture",
            compiled_program_ref: "igapp/polymorphic_add@v0",
            semanticir_artifact_ref: "semantic_ir/polymorphic_add@v0",
            runtime_steps: [
              {
                step: "runtime.evaluate_add_integer",
                status: "ok",
                value_hash: "sha256:integer-result-observation"
              }
            ],
            report_only: true,
            runtime_enforced: false
          }
        ]
      }
    )

    expect(report).to be_ok
    expect(report.metadata.fetch(:semantics)).to include(
      report_only: true,
      runtime_enforced: false,
      execution_authorized: false,
      ledger_core: false
    )
    expect(report.metadata.fetch(:custom_sections).fetch(:semanticir_verification_profiles).length).to eq(5)
  end

  it "manifests SemanticIR custom section count and profile names" do
    report = build_report(
      redaction_policy: redaction_policy,
      custom_sections: {
        semanticir_verification_profiles: [
          { profile: "semanticir_artifact_profile_v0" },
          { profile: "classifier_diagnostic_profile_v0" },
          { profile: "typecheck_diagnostic_profile_v0" },
          { profile: "oof_finding_profile_v0" },
          { profile: "runtime_proof_receipt_profile_v0" }
        ]
      }
    )

    expect(report.carrier_manifest.to_h.fetch(:sections)).to eq([
                                                                  {
                                                                    section_name: :semanticir_verification_profiles,
                                                                    count: 5,
                                                                    profile_names: %w[
                                                                      semanticir_artifact_profile_v0
                                                                      classifier_diagnostic_profile_v0
                                                                      typecheck_diagnostic_profile_v0
                                                                      oof_finding_profile_v0
                                                                      runtime_proof_receipt_profile_v0
                                                                    ],
                                                                    custom: true,
                                                                    report_only: true,
                                                                    runtime_enforced: false,
                                                                    raw_ref_export: false
                                                                  }
                                                                ])
  end

  it "rejects raw refs in SemanticIR carrier profiles" do
    expect do
      build_report(
        redaction_policy: redaction_policy,
        custom_sections: {
          semanticir_verification_profiles: [
            {
              profile: "semanticir_artifact_profile_v0",
              source_program_ref: "raw:source/polymorphic_add.ig"
            }
          ]
        }
      )
    end.to raise_error(ArgumentError, /raw refs/)
  end
end
