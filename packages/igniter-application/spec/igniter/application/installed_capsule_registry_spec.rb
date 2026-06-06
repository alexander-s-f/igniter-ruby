# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "installed capsule registry" do
  it "records complete transfer receipts as installed capsule entries" do
    Dir.mktmpdir("igniter-installed-capsules") do |root|
      registry = Igniter::Application.file_backed_installed_capsule_registry(root: root)
      receipt = {
        complete: true,
        valid: true,
        committed: true,
        artifact_path: File.join(root, "bundle"),
        destination_root: File.join(root, "destination"),
        counts: { planned: 1, applied: 1, verified: 1, findings: 0, refusals: 0, skipped: 0, manual_actions: 0 },
        findings: [],
        refusals: [],
        skipped: []
      }

      entry = Igniter::Application.record_installed_capsule(
        :horoscope,
        receipt: receipt,
        registry: registry,
        source: "local-hub",
        version: "0.1.0",
        metadata: { audience: :companion }
      )

      expect(entry.to_h).to include(
        name: :horoscope,
        status: :installed,
        complete: true,
        valid: true,
        committed: true,
        source: "local-hub",
        version: "0.1.0"
      )
      expect(registry.installed?(:horoscope)).to be(true)
      expect(registry.fetch(:horoscope).metadata).to eq(audience: "companion")
      expect(registry.entries.map(&:name)).to eq([:horoscope])
      expect(registry.history(:horoscope).length).to eq(1)
      expect(registry.history(:horoscope).first).to include(
        event_type: "installed_capsule_recorded",
        capsule: "horoscope",
        sequence: 1,
        status: "installed",
        version: "0.1.0"
      )
    end
  end

  it "keeps incomplete transfer receipts visible as blocked entries" do
    Dir.mktmpdir("igniter-installed-capsules") do |root|
      registry = Igniter::Application.file_backed_installed_capsule_registry(root: root)

      entry = registry.record(
        :operator,
        receipt: {
          complete: false,
          valid: true,
          committed: true,
          manual_actions: [{ type: :confirm_provider }]
        }
      )

      expect(entry.status).to eq(:blocked)
      expect(entry.installed?).to be(false)
      expect(registry.history(:operator).first).to include(
        status: "blocked",
        complete: false
      )
      expect(registry.installed?(:missing)).to be(false)
    end
  end

  it "keeps current entry separate from append-only install history" do
    Dir.mktmpdir("igniter-installed-capsules") do |root|
      registry = Igniter::Application.file_backed_installed_capsule_registry(root: root)
      complete_receipt = {
        complete: true,
        valid: true,
        committed: true
      }

      registry.record(:horoscope, receipt: complete_receipt, source: "local-hub", version: "0.1.0")
      registry.record(:horoscope, receipt: complete_receipt, source: "local-hub", version: "0.2.0")

      expect(registry.fetch(:horoscope).version).to eq("0.2.0")
      expect(registry.history(:horoscope).map { |event| event.fetch(:version) }).to eq(%w[0.1.0 0.2.0])
      expect(registry.history(:horoscope).map { |event| event.fetch(:sequence) }).to eq([1, 2])
      expect(registry.to_h.fetch(:history_count)).to eq(2)
    end
  end
end
