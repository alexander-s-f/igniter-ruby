# frozen_string_literal: true

require "spec_helper"
require "igniter/sdk/tools"

RSpec.describe Igniter::Tools::SystemDiscoveryTool do
  describe ".tool_name" do
    it "has a stable tool name" do
      expect(described_class.tool_name).to eq("system_discovery_tool")
    end
  end

  describe ".to_schema" do
    it "describes the system discovery inputs" do
      schema = described_class.to_schema

      expect(schema[:description]).to include("structured snapshot")
      expect(schema.dig(:parameters, "properties")).to include(
        "include_environment",
        "environment_keys",
        "utility_candidates",
        "scan_path_entries",
        "path_entry_limit"
      )
    end
  end

  describe "#call_with_capability_check!" do
    it "requires :system_read capability" do
      expect {
        described_class.new.call_with_capability_check!(allowed_capabilities: [])
      }.to raise_error(Igniter::Tool::CapabilityError, /system_read/)
    end

    it "returns a structured snapshot when capability is allowed" do
      result = described_class.new.call_with_capability_check!(
        allowed_capabilities: [:system_read],
        include_environment: true,
        environment_keys: %w[HOME PATH SHELL],
        utility_candidates: %w[ruby definitely-not-installed],
        scan_path_entries: false
      )

      expect(result).to include(:generated_at, :host, :runtime, :paths, :environment)
      expect(result.dig(:runtime, :ruby, :version)).to eq(RUBY_VERSION)
      expect(result.dig(:paths, :utility_candidates)).to include(
        a_hash_including(name: "ruby", present: be(true)),
        a_hash_including(name: "definitely-not-installed", present: false, path: nil)
      )
      expect(result.dig(:environment, "PATH")).to eq(ENV["PATH"])
      expect(result.dig(:paths, :discovered_executables)).to eq([])
    end
  end

  describe "#call" do
    it "limits discovered executables when scanning PATH" do
      result = described_class.new.call(
        utility_candidates: [],
        scan_path_entries: true,
        path_entry_limit: 5
      )

      expect(result.dig(:paths, :discovered_executables).size).to be <= 5
    end
  end
end
