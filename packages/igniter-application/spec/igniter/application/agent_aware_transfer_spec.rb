# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "../../spec_helper"

RSpec.describe "agent-aware capsule transfer" do
  it "carries declared agents through capsule reports, handoff, inventory, and receipts" do
    Dir.mktmpdir("igniter-agent-transfer") do |root|
      capsule_root = File.join(root, "companion")
      artifact = File.join(root, "companion_bundle")
      destination = File.join(root, "destination")

      FileUtils.mkdir_p(File.join(capsule_root, "agents"))
      FileUtils.mkdir_p(File.join(capsule_root, "providers"))
      FileUtils.mkdir_p(File.join(capsule_root, "services"))
      FileUtils.mkdir_p(File.join(capsule_root, "spec"))
      File.write(File.join(capsule_root, "agents/daily_companion.rb"), "# agent\n")
      File.write(File.join(capsule_root, "igniter.rb"), "# config\n")

      capsule = Igniter::Application.capsule(:companion, root: capsule_root, env: :test) do
        layout :capsule
        groups :agents, :services
        provider :openai
        service :companion_store
        agent :daily_companion,
              ai: :openai,
              instructions: "Give one practical next action.",
              tools: [:complete_reminder],
              metadata: { capsule: :daily_summary }
        export :daily_companion, kind: :agent
      end

      blueprint = capsule.to_blueprint
      report = blueprint.capsule_report.to_h
      handoff = Igniter::Application.handoff_manifest(subject: :companion_bundle, capsules: [capsule])
      inventory = Igniter::Application.transfer_inventory(capsule)
      readiness = Igniter::Application.transfer_readiness(handoff_manifest: handoff, transfer_inventory: inventory)
      bundle_plan = Igniter::Application.transfer_bundle_plan(transfer_readiness: readiness)
      Igniter::Application.write_transfer_bundle(bundle_plan, output: artifact)
      verification = Igniter::Application.verify_transfer_bundle(artifact)
      intake = Igniter::Application.transfer_intake_plan(verification, destination_root: destination)
      apply_plan = Igniter::Application.transfer_apply_plan(intake)
      committed = Igniter::Application.apply_transfer_plan(apply_plan, commit: true)
      applied_verification = Igniter::Application.verify_applied_transfer(committed, apply_plan: apply_plan)
      receipt = Igniter::Application.transfer_receipt(
        applied_verification,
        apply_result: committed,
        apply_plan: apply_plan
      )

      expected_agent = include(
        name: :daily_companion,
        ai_provider: :openai,
        instructions: "Give one practical next action.",
        tools: [:complete_reminder],
        metadata: { capsule: :daily_summary }
      )

      expect(report.fetch(:agents)).to include(expected_agent)
      expect(handoff.to_h.fetch(:capsules).first.fetch(:agents)).to include(expected_agent)
      expect(inventory.to_h.fetch(:capsules).first.fetch(:agents)).to include(expected_agent)
      expect(readiness).to be_ready
      expect(intake.to_h.fetch(:agent_capabilities)).to include(include(name: :daily_companion, capsule: :companion))
      expect(apply_plan.to_h.fetch(:agent_capabilities)).to include(include(name: :daily_companion, capsule: :companion))
      expect(receipt.to_h.fetch(:agent_capabilities)).to include(include(name: :daily_companion, capsule: :companion))
    end
  end

  it "blocks transfer readiness when an agent AI provider is not declared" do
    Dir.mktmpdir("igniter-agent-transfer-missing-provider") do |root|
      capsule = Igniter::Application.capsule(:companion, root: root, env: :test) do
        layout :capsule
        groups :agents
        agent :daily_companion, ai: :openai
      end

      readiness = Igniter::Application.transfer_readiness(capsule)
      blocker = readiness.to_h.fetch(:blockers).find do |entry|
        entry.fetch(:code) == :missing_agent_ai_provider
      end

      expect(readiness).not_to be_ready
      expect(blocker).to include(
        source: :agents,
        metadata: include(capsule: :companion, agent: :daily_companion, ai_provider: :openai)
      )
    end
  end
end
