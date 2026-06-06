# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Store::TBackendAdapterDescriptor do
  let(:ledger_protocol_ops) do
    %i[
      register_descriptor
      write
      append
      write_fact
      read
      query
      metadata_snapshot
      descriptor_snapshot
      sync_hub_profile
      replay
      compact
      subscribe
    ]
  end

  let(:metadata_snapshot) do
    {
      schema_version: 1,
      stores: [
        {
          schema_version: 1,
          kind: :store,
          name: :tasks,
          key: :id,
          capabilities: %i[write current_read as_of_read]
        }
      ],
      histories: [
        {
          schema_version: 1,
          kind: :history,
          name: :task_events,
          key: :task_id,
          event_field: :event,
          timestamp_field: :at
        }
      ],
      subscriptions: [
        {
          schema_version: 1,
          kind: :subscription,
          name: :task_events_changed,
          source: :task_events
        }
      ],
      retention: {
        policies: []
      },
      extensions: {
        ignored_optional_key: true
      }
    }
  end

  let(:descriptor_snapshot) do
    {
      schema_version: 1,
      stores: [
        {
          schema_version: 1,
          kind: :store,
          name: :tasks,
          key: :id,
          capabilities: %i[write current_read as_of_read]
        }
      ],
      histories: [
        {
          schema_version: 1,
          kind: :history,
          name: :task_events,
          key: :task_id,
          event_field: :event,
          timestamp_field: :at
        }
      ],
      subscriptions: []
    }
  end

  def build_descriptor(metadata_snapshot:, descriptor_snapshot:, ledger_protocol_ops:, schema_fingerprint: "sha256:compiled-schema")
    described_class.build(
      metadata_snapshot: metadata_snapshot,
      descriptor_snapshot: descriptor_snapshot,
      schema_fingerprint: schema_fingerprint,
      ledger_protocol_ops: ledger_protocol_ops
    )
  end

  it "builds a metadata-only Ledger TBackend descriptor from snapshots" do
    descriptor = build_descriptor(
      metadata_snapshot: metadata_snapshot,
      descriptor_snapshot: descriptor_snapshot,
      ledger_protocol_ops: ledger_protocol_ops
    )

    expect(descriptor.to_h).to include(
      kind: "ledger_tbackend_adapter_descriptor",
      adapter_kind: "ledger_open_protocol",
      adapter_version: "0.1.0",
      contract_version: "tbackend.v0",
      protocol: "igniter_store",
      protocol_schema_version: 1,
      evidence_mode: "receipt_required",
      schema_fingerprint: "sha256:compiled-schema"
    )
    expect(descriptor.supported_tbackend_ops).to eq(%w[read append replay snapshot compact subscribe])
    expect(descriptor.hook_methods).to eq(%w[read_as_of bihistory_at])
    expect(descriptor.capabilities).to eq(%w[history_read bihistory_read])
    expect(descriptor.history_axes).to eq(%w[valid_time transaction_time])
    expect(descriptor.cursor_policy).to include(
      ordered: "forward",
      cursor_kinds: ["timestamp"],
      truncation_reported: true,
      tie_breaker: "timestamp_then_fact_id_required"
    )
  end

  it "is visible through the pre-v1 Igniter::Ledger alias without a separate public class" do
    expect(Igniter::Ledger::TBackendAdapterDescriptor).to be(described_class)
  end

  it "computes stable descriptor hashes independent of hash key order" do
    reordered_metadata = {
      extensions: metadata_snapshot.fetch(:extensions),
      retention: metadata_snapshot.fetch(:retention),
      subscriptions: metadata_snapshot.fetch(:subscriptions),
      histories: metadata_snapshot.fetch(:histories),
      stores: metadata_snapshot.fetch(:stores),
      schema_version: 1
    }
    first = build_descriptor(
      metadata_snapshot: metadata_snapshot,
      descriptor_snapshot: descriptor_snapshot,
      ledger_protocol_ops: ledger_protocol_ops
    )
    second = build_descriptor(
      metadata_snapshot: reordered_metadata,
      descriptor_snapshot: descriptor_snapshot,
      ledger_protocol_ops: ledger_protocol_ops
    )

    expect(second.descriptor_hash).to eq(first.descriptor_hash)
    expect(second.descriptor_registry_hash).to eq(first.descriptor_registry_hash)
  end

  it "changes descriptor_registry_hash when descriptor snapshot content changes" do
    original = build_descriptor(
      metadata_snapshot: metadata_snapshot,
      descriptor_snapshot: descriptor_snapshot,
      ledger_protocol_ops: ledger_protocol_ops
    )
    changed = build_descriptor(
      metadata_snapshot: metadata_snapshot,
      descriptor_snapshot: descriptor_snapshot.merge(
        histories: descriptor_snapshot.fetch(:histories) + [
          {
            schema_version: 1,
            kind: :history,
            name: :audit_events,
            key: :subject_id
          }
        ]
      ),
      ledger_protocol_ops: ledger_protocol_ops
    )

    expect(changed.descriptor_registry_hash).not_to eq(original.descriptor_registry_hash)
  end

  it "reports ok diagnostics for satisfied metadata-only requirements" do
    descriptor = build_descriptor(
      metadata_snapshot: metadata_snapshot,
      descriptor_snapshot: descriptor_snapshot,
      ledger_protocol_ops: ledger_protocol_ops
    )

    diagnostic = descriptor.diagnostics(
      required_ops: %w[read append replay snapshot],
      required_hook_methods: %w[read_as_of bihistory_at],
      required_capabilities: %w[history_read bihistory_read],
      history_axes: %w[valid_time transaction_time],
      schema_fingerprint: "sha256:compiled-schema"
    )

    expect(diagnostic).to include(
      kind: "ledger_tbackend_adapter_descriptor_diagnostics",
      status: "ok",
      missing_ops: [],
      missing_hook_methods: [],
      missing_capabilities: [],
      missing_axes: [],
      schema_fingerprint_match: true,
      descriptor_hash: descriptor.descriptor_hash,
      descriptor_registry_hash: descriptor.descriptor_registry_hash
    )
  end

  it "diagnoses missing protocol ops as blocked" do
    descriptor = build_descriptor(
      metadata_snapshot: metadata_snapshot,
      descriptor_snapshot: descriptor_snapshot,
      ledger_protocol_ops: %i[read query metadata_snapshot]
    )

    diagnostic = descriptor.diagnostics(required_ops: %w[read append replay snapshot])

    expect(diagnostic).to include(status: "blocked")
    expect(diagnostic.fetch(:missing_ops)).to eq(%w[append replay])
  end

  it "diagnoses missing history descriptors as blocked for BiHistory requirements" do
    no_history_metadata = metadata_snapshot.merge(histories: [])
    no_history_descriptor_snapshot = descriptor_snapshot.merge(histories: [])
    descriptor = build_descriptor(
      metadata_snapshot: no_history_metadata,
      descriptor_snapshot: no_history_descriptor_snapshot,
      ledger_protocol_ops: ledger_protocol_ops
    )

    diagnostic = descriptor.diagnostics(
      required_hook_methods: %w[read_as_of bihistory_at],
      required_capabilities: %w[history_read bihistory_read],
      history_axes: %w[valid_time transaction_time]
    )

    expect(descriptor.hook_methods).to eq(%w[read_as_of])
    expect(descriptor.capabilities).to eq(%w[history_read])
    expect(descriptor.history_axes).to eq(%w[valid_time])
    expect(diagnostic).to include(status: "blocked")
    expect(diagnostic.fetch(:missing_hook_methods)).to eq(%w[bihistory_at])
    expect(diagnostic.fetch(:missing_capabilities)).to eq(%w[bihistory_read])
    expect(diagnostic.fetch(:missing_axes)).to eq(%w[transaction_time])
  end

  it "diagnoses schema fingerprint mismatch as blocked" do
    descriptor = build_descriptor(
      metadata_snapshot: metadata_snapshot,
      descriptor_snapshot: descriptor_snapshot,
      ledger_protocol_ops: ledger_protocol_ops
    )

    diagnostic = descriptor.diagnostics(schema_fingerprint: "sha256:other-schema")

    expect(diagnostic).to include(
      status: "blocked",
      schema_fingerprint_match: false
    )
  end

  it "exposes non-authorization flags and no operational adapter methods" do
    descriptor = build_descriptor(
      metadata_snapshot: metadata_snapshot,
      descriptor_snapshot: descriptor_snapshot,
      ledger_protocol_ops: ledger_protocol_ops
    )

    expect(descriptor.to_h.fetch(:non_authorization)).to eq(
      runtime_binding: false,
      ledger_reads: false,
      ledger_writes: false,
      ledger_append: false,
      ledger_replay: false,
      ledger_compact: false,
      ledger_subscribe: false,
      migration_execution: false
    )
    expect(descriptor).not_to respond_to(:read_as_of)
    expect(descriptor).not_to respond_to(:bihistory_at)
    expect(descriptor).not_to respond_to(:read)
    expect(descriptor).not_to respond_to(:write)
    expect(descriptor).not_to respond_to(:append)
    expect(descriptor).not_to respond_to(:replay)
    expect(descriptor).not_to respond_to(:compact)
    expect(descriptor).not_to respond_to(:subscribe)
  end
end
