# frozen_string_literal: true

require_relative "../spec_helper"
require "igniter/lang"

RSpec.describe Igniter::Lang::DiagnosticPayload do
  let(:availability_payload) do
    {
      subject: {
        projection: "availability[technician, requested_window]",
        tenant_scope: {
          company_ref: "redacted:company:fixture-acme",
          scope_version: "tenant-scope-v1"
        },
        technician_ref: "redacted:technician:t-17"
      },
      scoped_reads: [
        {
          subject: "technician_profile",
          type: "TechnicianProfile",
          read_ref: "obs/scoped-read-technician-profile",
          cardinality_bound: { min: 1, max: 1, source: "declared" }
        }
      ],
      slot_summary: {
        available_count: 4,
        blocked_count: 3,
        source_refs: {
          busy: ["redacted:schedule:t-17-20260506-10"]
        }
      },
      pipeline: {
        failed_step: nil,
        failure_kind: nil,
        trace_ref: "obs/pipeline-trace-positive"
      }
    }
  end

  def build_payload(**overrides)
    described_class.new(**{
      diagnostic_id: "diagnostic:availability:positive",
      profile: "availability_diagnostics_v0",
      status: :ok,
      decision: :trusted,
      payload: availability_payload,
      evidence_links: {
        trace_ref: "obs/pipeline-trace-positive",
        tenant_scope_ref: "obs/tenant-scope-source"
      },
      redaction_policy: {
        profile: "public_metadata_v0",
        redacted_ref_kinds: %w[company technician schedule],
        raw_ref_export: false,
        hash_source_refs: true
      },
      metadata: { source: :spec }
    }.merge(overrides))
  end

  it "builds an immutable report-only metadata diagnostic with redaction policy" do
    diagnostic = build_payload

    expect(diagnostic).to be_frozen
    expect(diagnostic).to be_report_only
    expect(diagnostic).not_to be_runtime_enforced
    expect(diagnostic.to_h).to include(
      diagnostic_id: "diagnostic:availability:positive",
      profile: "availability_diagnostics_v0",
      status: :ok,
      decision: :trusted
    )
    expect(diagnostic.to_h.fetch(:redaction_policy)).to include(
      profile: "public_metadata_v0",
      raw_ref_export: false,
      hash_source_refs: true,
      redacted_ref_kinds: %w[company technician schedule]
    )
    expect(diagnostic.to_h.fetch(:semantics)).to eq(
      report_only: true,
      runtime_enforced: false,
      package_adapter_authorized: false,
      real_data_export_authorized: false,
      readiness_enforced: false,
      ledger_core: false
    )
  end

  it "supports future operation-profile metadata without package-specific classes" do
    diagnostic = build_payload(
      diagnostic_id: "diagnostic:operation:policy",
      profile: "operation_action_diagnostic_v0",
      payload: {
        operation_ref: "operation/fixture/cancel-request",
        decision: {
          visible: true,
          hidden: false,
          executable: true,
          compatibility_decision: "trusted"
        },
        reasons: {
          visible: ["actor_can_request_for_open_subject"],
          hidden: [],
          executable: ["fresh_context_policy_passed"]
        }
      },
      evidence_links: {
        operation_context_ref: "obs/operation-context-001",
        actor_observation_ref: "obs/actor-001"
      },
      redaction_policy: {
        profile: "operation_action_public_metadata_v0",
        redacted_ref_kinds: %w[actor user employee order schedule provider],
        raw_ref_export: false,
        hash_source_refs: true
      }
    )

    expect(diagnostic.to_h.fetch(:profile)).to eq("operation_action_diagnostic_v0")
    expect(diagnostic.to_h.fetch(:payload).fetch(:reasons).fetch(:visible)).to eq([
                                                                                    "actor_can_request_for_open_subject"
                                                                                  ])
  end

  it "defaults to no raw ref export when redaction policy is omitted" do
    diagnostic = build_payload(redaction_policy: {})

    expect(diagnostic.to_h.fetch(:redaction_policy)).to include(
      raw_ref_export: false,
      hash_source_refs: true,
      redacted_ref_kinds: []
    )
  end

  it "rejects raw ref export in v0" do
    expect do
      build_payload(redaction_policy: { raw_ref_export: true })
    end.to raise_error(ArgumentError, /raw_ref_export true/)
  end

  it "rejects raw refs in payloads and evidence links" do
    expect do
      build_payload(payload: availability_payload.merge(technician_ref: "raw:technician:t-17"))
    end.to raise_error(ArgumentError, /raw refs/)

    expect do
      build_payload(evidence_links: { raw_ref: "provider/system/technician/17" })
    end.to raise_error(ArgumentError, /raw refs/)
  end

  it "rejects unknown status and decision values" do
    expect do
      build_payload(status: :ready)
    end.to raise_error(ArgumentError, /status/)

    expect do
      build_payload(decision: :allowed)
    end.to raise_error(ArgumentError, /decision/)
  end
end
