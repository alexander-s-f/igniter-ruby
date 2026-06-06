# frozen_string_literal: true

require_relative "../spec_helper"
require "igniter/lang"

RSpec.describe "Compiler pass VerificationReport metadata carriers" do
  let(:redaction_policy) do
    {
      profile: "compiler_pass_public_metadata_v0",
      raw_ref_export: false,
      hash_source_refs: true,
      redacted_ref_kinds: %w[source_path workspace_path host_path agent_ref runtime_ref]
    }
  end

  def build_report(metadata)
    Igniter::Lang::VerificationReport.new(
      profile_fingerprint: "profile:compiler-pipeline",
      operations: [],
      metadata: metadata
    )
  end

  it "carries separated compiler pass profiles as opaque custom metadata" do
    report = build_report(
      redaction_policy: redaction_policy,
      custom_sections: {
        compiler_pipeline_profiles: [
          {
            profile: "parsed_program_profile_v0",
            profile_kind: "ParsedProgramProfile",
            parsed_program_ref: "parsed_program/add@v0",
            source_program_ref: "source/add.ig",
            parser_status: "accepted",
            syntax_nodes: %w[contract input compute output],
            evidence_refs: ["proof/source_to_semanticir/parser/add"],
            report_only: true,
            runtime_enforced: false
          },
          {
            profile: "classified_program_profile_v0",
            profile_kind: "ClassifiedProgramProfile",
            classified_program_ref: "classified_program/add@v0",
            parsed_program_ref: "parsed_program/add@v0",
            classifier_status: "accepted",
            fragment_classes: %w[input compute output],
            evidence_refs: ["proof/source_to_semanticir/classifier/add"],
            report_only: true,
            runtime_enforced: false
          },
          {
            profile: "semanticir_program_profile_v0",
            profile_kind: "SemanticIRProgramProfile",
            semanticir_program_ref: "semantic_ir/add@v0",
            typed_program_ref: "typed_program/add@v0",
            artifact_hash: "sha256:canonical-semanticir-envelope",
            semanticir_status: "emitted",
            invariant_summary: {
              unresolved_symbols: 0,
              oof_findings: 0
            },
            evidence_refs: ["fixture/source_to_semanticir/golden/add.semantic_ir.json"],
            report_only: true,
            runtime_enforced: false
          },
          {
            profile: "typed_program_profile_v0",
            profile_kind: "TypedProgramProfile",
            typed_program_ref: "typed_program/add@v0",
            classified_program_ref: "classified_program/add@v0",
            typechecker_status: "accepted",
            typed_contract_refs: ["Add"],
            typecheck_results: [
              {
                contract_ref: "Add",
                input_types: { left: "Integer", right: "Integer" },
                output_types: { sum: "Integer" },
                decision: "accepted"
              }
            ],
            invariants: {
              type_variables_remaining: 0,
              unresolved_impls: 0
            },
            evidence_refs: ["proof/source_to_semanticir/typechecker/add"],
            report_only: true,
            runtime_enforced: false
          },
          {
            profile: "compiler_oof_diagnostic_profile_v0",
            profile_kind: "CompilerOOFDiagnosticProfile",
            diagnostic_ref: "diagnostic/compiler/unresolved-symbol@v0",
            pass: "semanticir_emission",
            oof_code: "OOF-UNRESOLVED-SYMBOL",
            severity: "error",
            decision: "rejected_before_semanticir",
            semanticir_emitted: false,
            evidence_refs: ["fixture/source_to_semanticir/golden/negative_unresolved_symbol.semantic_ir.json"],
            report_only: true,
            runtime_enforced: false
          },
          {
            profile: "runtime_load_receipt_profile_v0",
            profile_kind: "RuntimeLoadReceiptProfile",
            receipt_ref: "runtime_load/add@v0",
            runtime_ref: "redacted:runtime/synthetic-fixture",
            compiled_program_ref: "igapp/add@v0",
            semanticir_program_ref: "semantic_ir/add@v0",
            load_status: "execution_pending",
            loaded_contract_refs: ["Add"],
            blocked_contract_refs: [],
            evidence_refs: ["proof/source_to_semanticir/runtime-load/add"],
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
    expect(report.metadata.fetch(:redaction_policy)).to include(raw_ref_export: false)
    expect(report.metadata.fetch(:custom_sections).fetch(:compiler_pipeline_profiles).length).to eq(6)
    expect(report.metadata.fetch(:custom_sections).fetch(:compiler_pipeline_profiles).last).to include(
      profile: "runtime_load_receipt_profile_v0",
      load_status: "execution_pending"
    )
  end

  it "manifests compiler pipeline custom section count and profile names" do
    report = build_report(
      redaction_policy: redaction_policy,
      custom_sections: {
        compiler_pipeline_profiles: [
          { profile: "parsed_program_profile_v0" },
          { profile: "classified_program_profile_v0" },
          { profile: "typed_program_profile_v0" },
          { profile: "semanticir_program_profile_v0" },
          { profile: "compiler_oof_diagnostic_profile_v0" },
          { profile: "runtime_load_receipt_profile_v0" }
        ]
      }
    )

    expect(report.carrier_manifest.to_h.fetch(:sections)).to eq([
                                                                  {
                                                                    section_name: :compiler_pipeline_profiles,
                                                                    count: 6,
                                                                    profile_names: %w[
                                                                      parsed_program_profile_v0
                                                                      classified_program_profile_v0
                                                                      typed_program_profile_v0
                                                                      semanticir_program_profile_v0
                                                                      compiler_oof_diagnostic_profile_v0
                                                                      runtime_load_receipt_profile_v0
                                                                    ],
                                                                    custom: true,
                                                                    report_only: true,
                                                                    runtime_enforced: false,
                                                                    raw_ref_export: false
                                                                  }
                                                                ])
  end

  it "rejects raw refs in compiler pipeline carrier profiles" do
    expect do
      build_report(
        redaction_policy: redaction_policy,
        custom_sections: {
          compiler_pipeline_profiles: [
            {
              profile: "parsed_program_profile_v0",
              source_program_ref: "raw:source/add.ig"
            }
          ]
        }
      )
    end.to raise_error(ArgumentError, /raw refs/)
  end
end
