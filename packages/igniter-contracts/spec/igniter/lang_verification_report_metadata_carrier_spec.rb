# frozen_string_literal: true

require_relative "../spec_helper"
require "igniter/lang"

RSpec.describe Igniter::Lang::VerificationReport do
  let(:redaction_policy) do
    {
      profile: "public_metadata_v0",
      redacted_ref_kinds: %i[actor provider customer],
      raw_ref_export: false,
      hash_source_refs: true
    }
  end

  def build_report(metadata)
    described_class.new(
      profile_fingerprint: "profile:fingerprint",
      operations: [],
      metadata: metadata
    )
  end

  it "keeps ordinary metadata small and unchanged" do
    report = build_report(source: :compiled_artifact)

    expect(report.metadata).to eq(source: :compiled_artifact)
    expect(report.metadata).to be_frozen
    expect(report.carrier_manifest).to be_empty
    expect(report.to_h.fetch(:carrier_manifest)).to eq(sections: [])
  end

  it "carries opaque diagnostic and receipt metadata sections with report-only semantics" do
    report = build_report(
      diagnostics: [
        {
          profile: "projection_diagnostic_v0",
          status: "blocked",
          payload: {
            projection_ref: "projection/fixture/availability",
            failure_kind: "tenant_scope_mismatch"
          }
        }
      ],
      redaction_policy: redaction_policy,
      receipts: [
        {
          profile: "operation_request_receipt_v0",
          receipt_id: "operation_request/fixture/req-001",
          payload: {
            request_status: "pending",
            side_effects_performed: false
          }
        }
      ]
    )

    expect(report).to be_ok
    expect(report.metadata.fetch(:diagnostics).first.fetch(:payload)).to include(
      projection_ref: "projection/fixture/availability"
    )
    expect(report.metadata.fetch(:receipts).first.fetch(:payload)).to include(
      side_effects_performed: false
    )
    expect(report.metadata.fetch(:semantics)).to include(
      report_only: true,
      runtime_enforced: false,
      execution_authorized: false,
      provider_call_authorized: false,
      readiness_enforced: false,
      ledger_core: false
    )
    expect(report.carrier_manifest.to_h.fetch(:sections)).to eq([
                                                                  {
                                                                    section_name: :diagnostics,
                                                                    count: 1,
                                                                    profile_names: ["projection_diagnostic_v0"],
                                                                    custom: false,
                                                                    report_only: true,
                                                                    runtime_enforced: false,
                                                                    raw_ref_export: false
                                                                  },
                                                                  {
                                                                    section_name: :receipts,
                                                                    count: 1,
                                                                    profile_names: ["operation_request_receipt_v0"],
                                                                    custom: false,
                                                                    report_only: true,
                                                                    runtime_enforced: false,
                                                                    raw_ref_export: false
                                                                  }
                                                                ])
  end

  it "carries future model, scenario, and review report sections without public classes" do
    report = build_report(
      model_validity_reports: [
        {
          profile: "model_validity_report_v0",
          model_ref: "model/fixture/availability-score",
          status: "review_only"
        }
      ],
      scenario_comparison_reports: [
        {
          profile: "scenario_comparison_report_v0",
          baseline_ref: "scenario/fixture/baseline",
          candidate_ref: "scenario/fixture/candidate",
          decision: "review"
        }
      ],
      review_receipts: [
        {
          profile: "review_receipt_v0",
          reviewer_ref: "redacted:reviewer:agent",
          decision: "accepted_for_research"
        }
      ],
      redaction_policy: redaction_policy
    )

    serialized_metadata = report.to_h.fetch(:metadata)

    expect(serialized_metadata.fetch(:model_validity_reports).first).to include(
      model_ref: "model/fixture/availability-score"
    )
    expect(serialized_metadata.fetch(:scenario_comparison_reports).first).to include(
      candidate_ref: "scenario/fixture/candidate"
    )
    expect(serialized_metadata.fetch(:review_receipts).first).to include(
      reviewer_ref: "redacted:reviewer:agent"
    )
    expect(report.carrier_manifest.sections.map { |entry| entry.fetch(:section_name) }).to eq(%i[
                                                                                                model_validity_reports
                                                                                                scenario_comparison_reports
                                                                                                review_receipts
                                                                                              ])
  end

  it "supports explicitly marked custom carrier sections" do
    report = build_report(
      redaction_policy: redaction_policy,
      custom_sections: {
        future_confidence_reports: [
          {
            profile: "confidence_report_v0",
            subject_ref: "claim/fixture/availability",
            confidence: "medium"
          }
        ]
      }
    )

    expect(report.metadata.fetch(:custom_sections).fetch(:future_confidence_reports).first).to include(
      profile: "confidence_report_v0"
    )
    expect(report.carrier_manifest.to_h.fetch(:sections)).to eq([
                                                                  {
                                                                    section_name: :future_confidence_reports,
                                                                    count: 1,
                                                                    profile_names: ["confidence_report_v0"],
                                                                    custom: true,
                                                                    report_only: true,
                                                                    runtime_enforced: false,
                                                                    raw_ref_export: false
                                                                  }
                                                                ])
  end

  it "requires explicit redaction policy when carrier sections are present" do
    expect do
      build_report(diagnostics: [])
    end.to raise_error(ArgumentError, /metadata\.redaction_policy is required/)
  end

  it "normalizes supplied redaction policy while keeping raw ref export disabled" do
    report = build_report(
      diagnostics: [],
      redaction_policy: redaction_policy
    )

    expect(report.metadata.fetch(:redaction_policy)).to include(
      profile: "public_metadata_v0",
      redacted_ref_kinds: %w[actor provider customer],
      raw_ref_export: false,
      hash_source_refs: true
    )
  end

  it "rejects raw ref export for metadata carrier sections" do
    expect do
      build_report(
        diagnostics: [],
        redaction_policy: {
          raw_ref_export: true
        }
      )
    end.to raise_error(ArgumentError, /raw_ref_export true/)
  end

  it "rejects raw refs inside opaque carrier payloads" do
    expect do
      build_report(
        diagnostics: [
          {
            profile: "pipeline_diagnostic_v0",
            payload: {
              actor_ref: "raw:actor:tech-17"
            }
          }
        ],
        redaction_policy: redaction_policy
      )
    end.to raise_error(ArgumentError, /raw refs/)

    expect do
      build_report(
        receipts: [
          {
            profile: "operation_request_receipt_v0",
            raw_source_ref: "provider/session/001"
          }
        ],
        redaction_policy: redaction_policy
      )
    end.to raise_error(ArgumentError, /raw refs/)
  end

  it "rejects malformed known carrier sections" do
    expect do
      build_report(diagnostics: { profile: "pipeline_diagnostic_v0" }, redaction_policy: redaction_policy)
    end.to raise_error(ArgumentError, /metadata\.diagnostics must be an array/)

    expect do
      build_report(receipts: ["operation_request/fixture/req-001"], redaction_policy: redaction_policy)
    end.to raise_error(ArgumentError, /metadata\.receipts\[0\] must be a hash/)
  end

  it "rejects malformed custom carrier sections" do
    expect do
      build_report(custom_sections: [], redaction_policy: redaction_policy)
    end.to raise_error(ArgumentError, /metadata\.custom_sections must be a hash/)

    expect do
      build_report(
        redaction_policy: redaction_policy,
        custom_sections: {
          diagnostics: []
        }
      )
    end.to raise_error(ArgumentError, /duplicates a known section/)
  end
end
