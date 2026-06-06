# frozen_string_literal: true

require_relative "../spec_helper"
require "igniter/lang"

RSpec.describe "OSINT-style VerificationReport metadata carriers" do
  let(:redaction_policy) do
    {
      profile: "osint_public_metadata_v0",
      redacted_ref_kinds: %w[person user analyst source target account vendor],
      raw_ref_export: false,
      hash_source_refs: true
    }
  end

  def build_report(metadata)
    Igniter::Lang::VerificationReport.new(
      profile_fingerprint: "profile:fingerprint",
      operations: [],
      metadata: metadata
    )
  end

  it "carries OSINT-style profiles through custom sections without public OSINT classes" do
    report = build_report(
      redaction_policy: redaction_policy,
      custom_sections: {
        osint_trace_profiles: [
          {
            profile: "claim_trace_profile_v0",
            profile_kind: "ClaimTraceProfile",
            claim_ref: "claim/station-fixture-east-17/status-online/src-001",
            subject_ref: "redacted:station/fixture-east-17",
            predicate: "status",
            object_value: "online",
            source_links: ["source_obs/synthetic-bulletin-a/20260506T0900Z"],
            citation_policy_ref: "citation_policy/synthetic-public-summary@1",
            redaction_policy_ref: "redaction_policy/no-sensitive-fields@1",
            report_only: true,
            runtime_enforced: false
          }
        ],
        osint_product_profiles: [
          {
            profile: "evidence_linked_alert_profile_v0",
            profile_kind: "EvidenceLinkedAlertProfile",
            alert_ref: "contradiction_alert/vendor-payments/api-v2-deprecation-date",
            headline_claim_ref: "claim/vendor-payments/api-v2-deprecation/corrected",
            evidence_refs: ["evidence_link/product-ev-001"],
            status: "ready_for_human_review",
            recommended_safe_action: "review_sources",
            report_only: true,
            runtime_enforced: false
          },
          {
            profile: "daily_brief_profile_v0",
            profile_kind: "DailyBriefProfile",
            brief_ref: "daily_brief/personal-osint/20260506",
            watchlist_refs: ["watchlist/personal-osint/fixture-acme-payments@1"],
            snapshot_refs: ["factcheck/vendor-payments/asof-20260506T180000Z"],
            evidence_refs: ["evidence_link/product-ev-005"],
            report_only: true,
            runtime_enforced: false
          },
          {
            profile: "audit_ready_report_profile_v0",
            profile_kind: "AuditReadyReportProfile",
            report_ref: "audit_ready_report/vendor-payments/20260506",
            snapshot_ref: "factcheck/vendor-payments/asof-20260506T180000Z",
            evidence_refs: ["factcheck/vendor-payments/asof-20260506T180000Z"],
            reproducibility_status: "audit_ready_synthetic",
            report_only: true,
            runtime_enforced: false
          }
        ]
      }
    )

    expect(defined?(Igniter::Lang::ClaimTraceProfile)).to be_nil
    expect(defined?(Igniter::Lang::EvidenceLinkedAlertProfile)).to be_nil
    expect(defined?(Igniter::Lang::DailyBriefProfile)).to be_nil
    expect(defined?(Igniter::Lang::AuditReadyReportProfile)).to be_nil

    expect(report.metadata.fetch(:semantics)).to include(
      report_only: true,
      runtime_enforced: false,
      ledger_core: false
    )
    expect(report.metadata.fetch(:redaction_policy)).to include(raw_ref_export: false)
  end

  it "exposes OSINT custom section counts and profile names in carrier_manifest" do
    report = build_report(
      redaction_policy: redaction_policy,
      custom_sections: {
        osint_trace_profiles: [
          { profile: "claim_trace_profile_v0", profile_kind: "ClaimTraceProfile" }
        ],
        osint_product_profiles: [
          { profile: "evidence_linked_alert_profile_v0", profile_kind: "EvidenceLinkedAlertProfile" },
          { profile: "daily_brief_profile_v0", profile_kind: "DailyBriefProfile" },
          { profile: "audit_ready_report_profile_v0", profile_kind: "AuditReadyReportProfile" }
        ]
      }
    )

    expect(report.carrier_manifest.to_h.fetch(:sections)).to eq([
                                                                  {
                                                                    section_name: :osint_trace_profiles,
                                                                    count: 1,
                                                                    profile_names: ["claim_trace_profile_v0"],
                                                                    custom: true,
                                                                    report_only: true,
                                                                    runtime_enforced: false,
                                                                    raw_ref_export: false
                                                                  },
                                                                  {
                                                                    section_name: :osint_product_profiles,
                                                                    count: 3,
                                                                    profile_names: %w[
                                                                      evidence_linked_alert_profile_v0
                                                                      daily_brief_profile_v0
                                                                      audit_ready_report_profile_v0
                                                                    ],
                                                                    custom: true,
                                                                    report_only: true,
                                                                    runtime_enforced: false,
                                                                    raw_ref_export: false
                                                                  }
                                                                ])
  end

  it "requires explicit redaction policy for OSINT-style carriers" do
    expect do
      build_report(
        custom_sections: {
          osint_product_profiles: [
            { profile: "daily_brief_profile_v0", profile_kind: "DailyBriefProfile" }
          ]
        }
      )
    end.to raise_error(ArgumentError, /metadata\.redaction_policy is required/)
  end

  it "rejects raw refs in OSINT-style carriers" do
    expect do
      build_report(
        redaction_policy: redaction_policy,
        custom_sections: {
          osint_trace_profiles: [
            {
              profile: "claim_trace_profile_v0",
              profile_kind: "ClaimTraceProfile",
              source_links: ["raw:source/private-feed/001"]
            }
          ]
        }
      )
    end.to raise_error(ArgumentError, /raw refs/)
  end
end
