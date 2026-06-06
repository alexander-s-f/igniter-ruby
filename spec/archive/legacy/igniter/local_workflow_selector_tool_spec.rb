# frozen_string_literal: true

require "spec_helper"
require "igniter/sdk/tools"

RSpec.describe Igniter::Tools::LocalWorkflowSelectorTool do
  describe ".tool_name" do
    it "has a stable tool name" do
      expect(described_class.tool_name).to eq("local_workflow_selector_tool")
    end
  end

  describe "#call_with_capability_check!" do
    it "requires :system_read capability" do
      expect {
        described_class.new.call_with_capability_check!(allowed_capabilities: [])
      }.to raise_error(Igniter::Tool::CapabilityError, /system_read/)
    end

    it "recommends platformio workflow when pio is available" do
      tool = described_class.new

      allow(Igniter::Tools::SystemDiscoveryTool).to receive(:new).and_return(
        instance_double(
          Igniter::Tools::SystemDiscoveryTool,
          call: {
            generated_at: Time.now.utc.iso8601,
            host: { hostname: "dev-box" },
            runtime: { ruby: { version: RUBY_VERSION } },
            paths: {
              utility_candidates: [
                { name: "pio", present: true, path: "/usr/bin/pio" },
                { name: "ruby", present: true, path: "/usr/bin/ruby" },
                { name: "bundle", present: true, path: "/usr/bin/bundle" },
                { name: "git", present: true, path: "/usr/bin/git" },
                { name: "sqlite3", present: false, path: nil }
              ],
              discovered_executables: []
            }
          }
        )
      )

      result = tool.call_with_capability_check!(
        allowed_capabilities: [:system_read],
        goals: %w[esp32 hardware],
        include_discovery: false
      )

      expect(result[:recommended_workflows]).to include(
        a_hash_including(id: "platformio_esp32", available: true)
      )
      expect(result[:suggested_next_steps]).to include(a_string_including("pio run"))
      expect(result).not_to have_key(:discovery)
    end

    it "reports unavailable workflows with missing utilities" do
      tool = described_class.new

      allow(Igniter::Tools::SystemDiscoveryTool).to receive(:new).and_return(
        instance_double(
          Igniter::Tools::SystemDiscoveryTool,
          call: {
            generated_at: Time.now.utc.iso8601,
            host: {},
            runtime: {},
            paths: {
              utility_candidates: [
                { name: "docker", present: false, path: nil },
                { name: "bundle", present: true, path: "/usr/bin/bundle" },
                { name: "ruby", present: true, path: "/usr/bin/ruby" },
                { name: "git", present: true, path: "/usr/bin/git" }
              ],
              discovered_executables: []
            }
          }
        )
      )

      result = tool.call(
        goals: %w[containers],
        workflow_candidates: %w[docker_compose_dev],
        include_discovery: false
      )

      expect(result[:available_workflows]).to eq([])
      expect(result[:unavailable_workflows]).to include(
        a_hash_including(id: "docker_compose_dev", missing_utilities: ["docker"])
      )
    end
  end
end
