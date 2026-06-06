# frozen_string_literal: true

require_relative "../spec_helper"
require "igniter/lang"

RSpec.describe Igniter::Lang::SchemaCompatibilityDiagnostic do
  let(:evidence_links) do
    {
      compatibility_report_ref: "compatibility-report:current",
      semantic_image_ref: "semantic-image:old",
      loaded_schema_descriptor_ref: "schema-descriptor:new",
      migration_descriptor_ref: "migration-descriptor:single-hop",
      migration_receipt_ref: "migration-receipt:1"
    }
  end

  let(:migration_profile) do
    {
      migration_receipt_ref: "migration-receipt:1",
      replaces_image_id: "semantic-image:old",
      replacement_semantic_image_ref: "semantic-image:replacement",
      replacement_schema_fingerprint: "schema:fingerprint:new",
      loaded_schema_fingerprint: "schema:fingerprint:new",
      migration_chain: [],
      replacement_image_lifecycle: :session,
      migration_receipt_lifecycle: :audit,
      packet_links: {
        replaces: "semantic-image:old",
        caused_by: "migration-receipt:1",
        produced_by: "migration-intent:1",
        produced_in: "compatibility-report:post",
        has_supersedes: false
      },
      post_migration_report_ref: "compatibility-report:post",
      post_migration_schema_decision: :trusted,
      post_migration_compatibility_decision: :trusted
    }
  end

  def build_diagnostic(**overrides)
    described_class.new(**{
      diagnostic_id: "diagnostic:1",
      contract_ref: "contract:pricing",
      old_schema_version: 1,
      new_schema_version: 2,
      old_schema_fingerprint: "schema:fingerprint:old",
      new_schema_fingerprint: "schema:fingerprint:new",
      schema_check_outcome: :migrating,
      migration_available: true,
      compatibility_decision: :migrating,
      evidence_links: evidence_links,
      migration_ref: "migration:single-hop",
      metadata: { source: :spec }
    }.merge(overrides))
  end

  it "builds an immutable report-only diagnostic with fixed semantics" do
    diagnostic = build_diagnostic

    expect(diagnostic).to be_frozen
    expect(diagnostic).to be_report_only
    expect(diagnostic).not_to be_runtime_enforced
    expect(diagnostic.to_h).to include(
      diagnostic_id: "diagnostic:1",
      contract_ref: "contract:pricing",
      schema_check_outcome: :migrating,
      compatibility_decision: :migrating,
      status: :migrating,
      migration_available: true
    )
    expect(diagnostic.to_h.fetch(:semantics)).to eq(
      report_only: true,
      runtime_enforced: false,
      migration_execution_authorized: false,
      ledger_core: false
    )
  end

  it "requires compatibility, semantic image, and loaded schema evidence links" do
    expect do
      build_diagnostic(evidence_links: evidence_links.except(:compatibility_report_ref))
    end.to raise_error(ArgumentError, /evidence_links\.compatibility_report_ref/)

    expect do
      build_diagnostic(evidence_links: evidence_links.except(:semantic_image_ref))
    end.to raise_error(ArgumentError, /evidence_links\.semantic_image_ref/)

    expect do
      build_diagnostic(evidence_links: evidence_links.except(:loaded_schema_descriptor_ref))
    end.to raise_error(ArgumentError, /evidence_links\.loaded_schema_descriptor_ref/)
  end

  it "rejects unknown decisions" do
    expect do
      build_diagnostic(schema_check_outcome: :maybe)
    end.to raise_error(ArgumentError, /schema_check_outcome/)

    expect do
      build_diagnostic(compatibility_decision: :warn)
    end.to raise_error(ArgumentError, /compatibility_decision/)
  end

  it "requires migration evidence when migration_available is true" do
    links = evidence_links.except(:migration_descriptor_ref)

    expect do
      build_diagnostic(evidence_links: links, migration_ref: nil)
    end.to raise_error(ArgumentError, /migration_available/)
  end

  it "serializes optional single-hop migration profile P-1 through P-10 as metadata cases" do
    diagnostic = build_diagnostic(migration_profile: migration_profile)
    profile_cases = diagnostic.to_h.fetch(:profile_cases)

    expect(profile_cases.map { |entry| entry.fetch(:code) }).to eq(%w[
                                                                     P-1
                                                                     P-2
                                                                     P-3
                                                                     P-4
                                                                     P-5
                                                                     P-6
                                                                     P-7
                                                                     P-8
                                                                     P-9
                                                                     P-10
                                                                   ])
    expect(profile_cases.map { |entry| entry.fetch(:status) }.uniq).to eq([:trusted])
    expect(diagnostic.to_h.fetch(:migration_profile)).to include(
      migration_chain: [],
      replacement_image_lifecycle: :session,
      migration_receipt_lifecycle: :audit
    )
  end

  it "requires single-hop migration_chain metadata when a migration profile is present" do
    profile = migration_profile.merge(migration_chain: ["migration-receipt:previous"])
    diagnostic = build_diagnostic(migration_profile: profile)

    expect(diagnostic.to_h.fetch(:profile_cases).find { |entry| entry.fetch(:code) == "P-9" }).to include(
      status: :blocked
    )
    expect(diagnostic.to_h.fetch(:status)).to eq(:blocked)
  end

  it "blocks supersedes links in the profile without authorizing runtime enforcement" do
    profile = migration_profile.merge(
      packet_links: migration_profile.fetch(:packet_links).merge(has_supersedes: true)
    )
    diagnostic = build_diagnostic(migration_profile: profile)

    expect(diagnostic.to_h.fetch(:profile_cases).find { |entry| entry.fetch(:code) == "P-5" }).to include(
      status: :blocked
    )
    expect(diagnostic).to be_report_only
    expect(diagnostic).not_to be_runtime_enforced
  end

  it "represents OOF-MR3 wrong replacement fingerprint as blocked, not provisional" do
    profile = migration_profile.merge(
      replacement_schema_fingerprint: "schema:fingerprint:forged",
      post_migration_schema_decision: :blocked,
      post_migration_compatibility_decision: :blocked,
      oof_code: "OOF-MR3"
    )
    diagnostic = build_diagnostic(
      schema_check_outcome: :blocked,
      compatibility_decision: :blocked,
      migration_profile: profile
    )

    p10 = diagnostic.to_h.fetch(:profile_cases).find { |entry| entry.fetch(:code) == "P-10" }

    expect(p10).to include(status: :blocked, oof_code: "OOF-MR3")
    expect(diagnostic.to_h.fetch(:status)).to eq(:blocked)
    expect(diagnostic.to_h.fetch(:schema_check_outcome)).to eq(:blocked)
    expect(diagnostic.to_h.fetch(:compatibility_decision)).to eq(:blocked)
  end
end
