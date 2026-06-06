# frozen_string_literal: true

require "spec_helper"
require "igniter/sdk/tools"

RSpec.describe Igniter::Tools::AgentBootstrapTool do
  describe ".tool_name" do
    it "has a stable tool name" do
      expect(described_class.tool_name).to eq("agent_bootstrap_tool")
    end
  end

  describe "#call_with_capability_check!" do
    it "requires :system_read capability" do
      expect {
        described_class.new.call_with_capability_check!(allowed_capabilities: [], goal: "cluster_debug")
      }.to raise_error(Igniter::Tool::CapabilityError, /system_read/)
    end

    it "builds a bootstrap plan from the selected workflow" do
      allow(Igniter::Tools::LocalWorkflowSelectorTool).to receive(:new).and_return(
        instance_double(
          Igniter::Tools::LocalWorkflowSelectorTool,
          call: {
            recommended_workflows: [
              {
                id: "ruby_workspace_dev",
                label: "Ruby workspace development",
                recommended_commands: ["bundle install", "bundle exec rspec", "bin/dev"]
              }
            ],
            unavailable_workflows: []
          }
        )
      )

      result = described_class.new.call_with_capability_check!(
        allowed_capabilities: [:system_read],
        goal: "cluster_debug"
      )

      expect(result[:selected_workflow]).to include(id: "ruby_workspace_dev")
      expect(result[:bootstrap_steps]).to include(a_string_including("bundle install"))
      expect(result[:checklist]).not_to be_empty
      expect(result[:success_criteria]).not_to be_empty
    end

    it "returns diagnostics when no preferred workflow is available" do
      allow(Igniter::Tools::LocalWorkflowSelectorTool).to receive(:new).and_return(
        instance_double(
          Igniter::Tools::LocalWorkflowSelectorTool,
          call: {
            recommended_workflows: [],
            unavailable_workflows: [
              { id: "platformio_esp32", missing_utilities: ["pio"] }
            ]
          }
        )
      )

      result = described_class.new.call(goal: "esp32_bringup")

      expect(result[:selected_workflow]).to be_nil
      expect(result[:notes]).to include(a_string_including("platformio_esp32 missing pio"))
      expect(result[:bootstrap_steps]).to include(a_string_including("No preferred workflow"))
    end

    it "raises on unknown goals" do
      expect {
        described_class.new.call(goal: "made_up_goal")
      }.to raise_error(ArgumentError, /Unknown bootstrap goal/)
    end
  end
end
