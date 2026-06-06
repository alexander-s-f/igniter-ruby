# frozen_string_literal: true

require "igniter/durable_model"
require "igniter/durable_model/record"
require "igniter/durable_model/history"
require "igniter/durable_model/command_activity"
require "igniter/durable_model/command_flow_decision"
require "igniter/durable_model/command_flow_evidence_archive"
require "igniter/durable_model/receipts"
require "igniter/durable_model/command_intent"
require "igniter/durable_model/command_operation_plan"
require "igniter/durable_model/command_activity_event"
require "igniter/durable_model/command_policy_decision"
require "igniter/durable_model/command_lifecycle"
require "igniter/durable_model/command_flow"
require "igniter/durable_model/command_flow_slice"
require "igniter/durable_model/command_flow_monitor_result"
require "igniter/durable_model/command_flow_view_descriptor"
require "igniter/durable_model/command_flow_view"
require "igniter/durable_model/command_flow_view_pin"
require "igniter/durable_model/command_flow_decision_review"
require "igniter/durable_model/command_flow_evidence_profile"
require "igniter/durable_model/command_flow_evidence_export"
require "igniter/durable_model/command_flow_evidence_export_verification"
require "igniter/durable_model/store"
require_relative "../spec_helper"

RSpec.describe Igniter::DurableModel do
  let(:record_class) do
    Class.new do
      include Igniter::DurableModel::Record

      store_name :durable_reminders
      field :title
      field :status, default: :open

      scope :open, filters: { status: :open }
    end
  end

  let(:history_class) do
    Class.new do
      include Igniter::DurableModel::History

      history_name :durable_tracker_logs
      partition_key :tracker_id
      field :tracker_id
      field :value
    end
  end

  let(:record_manifest) do
    {
      storage: { shape: :store, name: :durable_manifest_records, key: :id },
      fields: [
        { name: :id, attributes: {} },
        { name: :title, attributes: {} },
        { name: :status, attributes: { default: :open } }
      ],
      scopes: [
        { name: :open, attributes: { where: { status: :open } } }
      ]
    }
  end

  let(:history_manifest) do
    {
      storage: { shape: :history, name: :durable_manifest_events, key: :tracker_id },
      history: { key: :tracker_id },
      fields: [
        { name: :tracker_id, attributes: {} },
        { name: :value, attributes: {} }
      ]
    }
  end

  it "exposes clear canonical and compatibility constant identity" do
    expect(described_class::Record).to equal(Igniter::Companion::Record)
    expect(described_class::History).to equal(Igniter::Companion::History)
    expect(described_class::CommandActivity).to equal(Igniter::Companion::CommandActivity)
    expect(described_class::CommandFlowDecision).to equal(Igniter::Companion::CommandFlowDecision)
    expect(described_class::CommandFlowEvidenceArchive).to equal(Igniter::Companion::CommandFlowEvidenceArchive)
    expect(described_class::Store).to equal(Igniter::Companion::Store)
    expect(described_class::WriteReceipt).to equal(Igniter::Companion::WriteReceipt)
    expect(described_class::AppendReceipt).to equal(Igniter::Companion::AppendReceipt)
    expect(described_class::CommandActivityReceipt).to equal(Igniter::Companion::CommandActivityReceipt)
    expect(described_class::CommandFlowDecisionReceipt).to equal(Igniter::Companion::CommandFlowDecisionReceipt)
    expect(described_class::CommandFlowEvidenceArchiveReceipt).to equal(Igniter::Companion::CommandFlowEvidenceArchiveReceipt)
    expect(described_class::CommandApplyReceipt).to equal(Igniter::Companion::CommandApplyReceipt)
    expect(described_class::CommandIntent).to equal(Igniter::Companion::CommandIntent)
    expect(described_class::CommandOperationPlan).to equal(Igniter::Companion::CommandOperationPlan)
    expect(described_class::CommandActivityEvent).to equal(Igniter::Companion::CommandActivityEvent)
    expect(described_class::CommandPolicyDecision).to equal(Igniter::Companion::CommandPolicyDecision)
    expect(described_class::CommandLifecycle).to equal(Igniter::Companion::CommandLifecycle)
    expect(described_class::CommandFlow).to equal(Igniter::Companion::CommandFlow)
    expect(described_class::CommandFlowSlice).to equal(Igniter::Companion::CommandFlowSlice)
    expect(described_class::CommandFlowMonitorResult).to equal(Igniter::Companion::CommandFlowMonitorResult)
    expect(described_class::CommandFlowViewDescriptor).to equal(Igniter::Companion::CommandFlowViewDescriptor)
    expect(described_class::CommandFlowView).to equal(Igniter::Companion::CommandFlowView)
    expect(described_class::CommandFlowViewPin).to equal(Igniter::Companion::CommandFlowViewPin)
    expect(described_class::CommandFlowDecisionReview).to equal(Igniter::Companion::CommandFlowDecisionReview)
    expect(described_class::CommandFlowEvidenceProfile).to equal(Igniter::Companion::CommandFlowEvidenceProfile)
    expect(described_class::CommandFlowEvidenceExport).to equal(Igniter::Companion::CommandFlowEvidenceExport)
    expect(described_class::CommandFlowEvidenceExportVerification).to equal(Igniter::Companion::CommandFlowEvidenceExportVerification)
  end

  it "defines command flow evidence archive history shape" do
    fields = described_class::CommandFlowEvidenceArchive._fields

    expect(described_class::CommandFlowEvidenceArchive.store_name).to eq(:command_flow_evidence_archives)
    expect(described_class::CommandFlowEvidenceArchive._partition_key).to eq(:owner)
    expect(fields).to include(
      owner: include(default: nil),
      view_name: include(default: nil),
      export_id: include(default: nil),
      content_hash: include(default: nil),
      privacy: include(default: nil),
      status: include(default: nil),
      meaning_status: include(default: nil),
      profile_kind: include(default: nil),
      canonical_json: include(default: nil),
      diagnostics: include(default: []),
      redactions: include(default: []),
      metadata: include(default: {}),
      store_fact_exposed: include(default: false),
      value_hash_exposed: include(default: false)
    )
  end

  it "defines command flow decision history shape" do
    fields = described_class::CommandFlowDecision._fields

    expect(described_class::CommandFlowDecision.store_name).to eq(:command_flow_decisions)
    expect(described_class::CommandFlowDecision._partition_key).to eq(:owner)
    expect(fields).to include(
      owner: include(default: nil),
      view_name: include(default: nil),
      action: include(default: nil),
      status: include(default: nil),
      meaning_status: include(default: nil),
      receipt_id: include(default: nil),
      decision_receipt_id: include(default: nil),
      horizon: include(default: {}),
      capabilities: include(default: []),
      missing_capabilities: include(default: []),
      summary: include(default: {}),
      errors: include(default: []),
      warnings: include(default: []),
      metadata: include(default: {}),
      store_fact_exposed: include(default: false),
      value_hash_exposed: include(default: false)
    )
  end

  it "supports register/write/read/scope through DurableModel::Store" do
    store = described_class::Store.new
    store.register(record_class)

    receipt = store.write(record_class, key: "r1", title: "Buy milk", status: :open)
    store.write(record_class, key: "r2", title: "Done", status: :done)

    expect(receipt).to be_a(described_class::WriteReceipt)
    expect(store.read(record_class, key: "r1").title).to eq("Buy milk")
    expect(store.scope(record_class, :open).map(&:key)).to eq(["r1"])
  ensure
    store&.close
  end

  it "supports append/replay through DurableModel::Store" do
    store = described_class::Store.new

    receipt = store.append(history_class, tracker_id: "sleep", value: 7.0)
    store.append(history_class, tracker_id: "sleep", value: 8.0)

    expect(receipt).to be_a(described_class::AppendReceipt)
    expect(store.replay(history_class).map(&:value)).to eq([7.0, 8.0])
  ensure
    store&.close
  end

  it "builds DurableModel record and history classes from manifests" do
    record = described_class::Record.from_manifest(record_manifest)
    history = described_class::History.from_manifest(history_manifest)

    expect(record.ancestors).to include(described_class::Record)
    expect(history.ancestors).to include(described_class::History)
    expect(record.store_name).to eq(:durable_manifest_records)
    expect(history.store_name).to eq(:durable_manifest_events)
  end

  it "dispatches from_manifest from both namespaces" do
    durable_record = described_class.from_manifest(record_manifest)
    compatible_history = Igniter::Companion.from_manifest(history_manifest)

    expect(durable_record.ancestors).to include(described_class::Record)
    expect(compatible_history.ancestors).to include(described_class::History)
  end

  it "keeps Companion compatibility usage working" do
    compatible = Class.new do
      include Igniter::Companion::Record
      store_name :compatible_records
      field :title
    end
    store = Igniter::Companion::Store.new

    store.write(compatible, key: "c1", title: "Still here")

    expect(store.read(compatible, key: "c1").title).to eq("Still here")
  ensure
    store&.close
  end

  it "keeps LedgerClient-backed stores working through the DurableModel namespace" do
    ledger = Igniter::Ledger::LedgerStore.new
    client = Igniter::LedgerClient.wrap(ledger.protocol)
    store = described_class::Store.new(client: client)
    store.register(record_class)

    store.write(record_class, key: "r1", title: "Remote", status: :open)

    expect(store.scope(record_class, :open).map(&:title)).to eq(["Remote"])
  ensure
    store&.close
  end
end
