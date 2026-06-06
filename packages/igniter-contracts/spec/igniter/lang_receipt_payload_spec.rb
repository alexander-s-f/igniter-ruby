# frozen_string_literal: true

require_relative "../spec_helper"
require "igniter/lang"

RSpec.describe Igniter::Lang::ReceiptPayload do
  let(:request_payload) do
    {
      request_ref: "operation_request/fixture/req-001",
      operation_ref: "operation/fixture/cancel-request",
      action_ref: "operation_action/appointment_cancel_request",
      action_kind: "request",
      request_status: "pending",
      receipt_status: "created",
      actor_ref: "redacted:actor:tech-17",
      subject_refs: {
        order_ref: "redacted:order:fixture-o-200",
        schedule_ref: "redacted:schedule:fixture-s-200"
      },
      idempotency: {
        idempotency_key: "hash:idempotency/request/schedule/action/pending",
        duplicate_of: nil,
        created_new_request: true,
        side_effects_performed: false
      }
    }
  end

  def build_receipt(**overrides)
    described_class.new(**{
      receipt_id: "operation_request/fixture/req-001",
      profile: "operation_request_receipt_v0",
      payload: request_payload,
      evidence_links: {
        operation_intent_ref: "obs/operation-intent-001",
        policy_diagnostic_ref: "operation_policy/fixture/action-001"
      },
      redaction_policy: {
        profile: "operation_receipt_public_metadata_v0",
        redacted_ref_kinds: %w[actor user employee order schedule provider],
        raw_ref_export: false,
        hash_source_refs: true
      },
      metadata: { source: :spec }
    }.merge(overrides))
  end

  it "builds an immutable report-only receipt payload with no execution authorization" do
    receipt = build_receipt

    expect(receipt).to be_frozen
    expect(receipt).to be_report_only
    expect(receipt).not_to be_runtime_enforced
    expect(receipt.to_h).to include(
      receipt_id: "operation_request/fixture/req-001",
      profile: "operation_request_receipt_v0",
      payload: request_payload
    )
    expect(receipt.to_h.fetch(:semantics)).to eq(
      report_only: true,
      runtime_enforced: false,
      execution_authorized: false,
      operation_execution_authorized: false,
      external_bridge_authorized: false,
      provider_call_authorized: false,
      real_data_export_authorized: false,
      ledger_core: false
    )
  end

  it "supports execution receipt metadata without executing operations" do
    receipt = build_receipt(
      receipt_id: "operation_execution/fixture/exec-001",
      profile: "operation_execution_receipt_v0",
      payload: {
        execution_ref: "operation_execution/fixture/exec-001",
        operation_ref: "operation/fixture/in-progress",
        action_kind: "execution",
        execution_status: "succeeded",
        state_transition: {
          subject_ref: "redacted:schedule:fixture-s-200",
          changed: true,
          summary: {
            status_from: "planned",
            status_to: "in_progress"
          }
        },
        performed_at: "2026-05-06T13:05:00Z"
      }
    )

    expect(receipt.to_h.fetch(:payload).fetch(:execution_status)).to eq("succeeded")
    expect(receipt.to_h.fetch(:semantics).fetch(:operation_execution_authorized)).to eq(false)
  end

  it "supports idempotency receipt metadata" do
    receipt = build_receipt(
      receipt_id: "operation_request/fixture/req-001-duplicate",
      profile: "operation_idempotency_receipt_v0",
      payload: {
        decision: "idempotent_no_op",
        receipt_status: "duplicate_pending_suppressed",
        original_request_ref: "operation_request/fixture/req-001",
        duplicate_request_ref: "operation_intent/fixture/cancel-request-duplicate-001",
        created_new_request: false,
        state_changed: false,
        side_effects_performed: false,
        diagnostics: [
          {
            code: "operation_request.duplicate_pending",
            severity: "info"
          }
        ]
      }
    )

    expect(receipt.to_h.fetch(:payload)).to include(
      decision: "idempotent_no_op",
      side_effects_performed: false
    )
  end

  it "supports external bridge receipt metadata without authorizing provider calls" do
    receipt = build_receipt(
      receipt_id: "external_operation_bridge/fixture/bridge-001",
      profile: "external_operation_bridge_receipt_v0",
      payload: {
        bridge_kind: "provider_neutral_work_item",
        provider_ref: "redacted:provider:helpdesk",
        external_subject_ref: "hash:external-subject/fixture-ticket-001",
        provider_receipt_ref: "hash:provider-receipt/fixture-ticket-001",
        bridge_status: "delivered",
        failure_kind: nil
      }
    )

    expect(receipt.to_h.fetch(:payload).fetch(:bridge_status)).to eq("delivered")
    expect(receipt.to_h.fetch(:semantics)).to include(
      external_bridge_authorized: false,
      provider_call_authorized: false
    )
  end

  it "defaults to no raw ref export when redaction policy is omitted" do
    receipt = build_receipt(redaction_policy: {})

    expect(receipt.to_h.fetch(:redaction_policy)).to include(
      raw_ref_export: false,
      hash_source_refs: true,
      redacted_ref_kinds: []
    )
  end

  it "rejects raw ref export and raw refs in receipt metadata" do
    expect do
      build_receipt(redaction_policy: { raw_ref_export: true })
    end.to raise_error(ArgumentError, /raw_ref_export true/)

    expect do
      build_receipt(payload: request_payload.merge(actor_ref: "raw:actor:tech-17"))
    end.to raise_error(ArgumentError, /raw refs/)

    expect do
      build_receipt(evidence_links: { raw_source_ref: "provider/session/001" })
    end.to raise_error(ArgumentError, /raw refs/)
  end
end
