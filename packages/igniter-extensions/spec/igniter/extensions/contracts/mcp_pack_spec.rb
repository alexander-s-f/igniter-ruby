# frozen_string_literal: true

require "tmpdir"

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::McpPack do
  it "installs debug and creator dependency packs" do
    profile = Igniter::Extensions::Contracts.build_profile(described_class)
    manifest = profile.pack_manifest(:extensions_mcp)

    expect(profile.pack_names).to include(:extensions_mcp, :extensions_debug, :extensions_creator)
    expect(manifest.requires_packs.map(&:name)).to eq(%i[extensions_debug extensions_creator])
  end

  it "publishes a tooling catalog" do
    catalog = described_class.tool_catalog
    names = catalog.map { |tool| tool.fetch(:name) }
    session_apply = catalog.find { |tool| tool.fetch(:name) == :creator_session_apply }

    expect(names).to include(
      :inspect_profile,
      :audit_pack,
      :creator_wizard,
      :creator_session_start,
      :creator_session_apply,
      :creator_session_workflow,
      :creator_session_write_plan,
      :creator_session_write,
      :creator_workflow,
      :creator_write_plan,
      :creator_write
    )
    expect(session_apply.fetch(:target)).to eq(:optional_profile_or_environment)
    expect(session_apply.fetch(:arguments).map { |argument| argument.fetch(:name) }).to eq(%i[session updates])
    expect(session_apply.fetch(:arguments).all? { |argument| argument.fetch(:required) }).to eq(true)
  end

  it "invokes creator and debug surfaces through a stable result envelope" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    wizard_result = Igniter::Extensions::Contracts.mcp_call(
      :creator_wizard,
      target: environment,
      name: :delivery,
      capabilities: %i[effect executor]
    )

    debug_result = Igniter::Extensions::Contracts.mcp_call(
      :debug_report,
      target: environment,
      inputs: { amount: 10 }
    ) do
      input :amount
      output :amount
    end

    expect(wizard_result.to_h.fetch(:payload).fetch(:pending_decisions).first.fetch(:key)).to eq(:scope)
    expect(debug_result.to_h.fetch(:payload).fetch(:execution).fetch(:outputs).fetch(:amount)).to eq(10)
  end

  it "can plan and write scaffolds through MCP-oriented creator tools" do
    Dir.mktmpdir("igniter-mcp-pack") do |dir|
      plan = Igniter::Extensions::Contracts.mcp_call(
        :creator_write_plan,
        name: :slug,
        profile: :feature_node,
        scope: :app_local,
        root: dir
      )

      write = Igniter::Extensions::Contracts.mcp_call(
        :creator_write,
        name: :slug,
        profile: :feature_node,
        scope: :app_local,
        root: dir
      )

      expect(plan.to_h.fetch(:mutating)).to eq(false)
      expect(write.to_h.fetch(:mutating)).to eq(true)
      expect(write.to_h.fetch(:payload).fetch(:files_written)).to eq(4)
    end
  end

  it "supports a serialized creator session flow for stepwise tooling" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    started = Igniter::Extensions::Contracts.mcp_call(
      :creator_session_start,
      target: environment,
      name: :delivery,
      capabilities: %i[effect executor]
    )

    updated = Igniter::Extensions::Contracts.mcp_call(
      :creator_session_apply,
      target: environment,
      session: started.to_h.fetch(:payload).fetch(:session),
      updates: { scope: :standalone_gem }
    )

    workflow = Igniter::Extensions::Contracts.mcp_call(
      :creator_session_workflow,
      target: environment,
      session: updated.to_h.fetch(:payload).fetch(:session)
    )

    expect(started.to_h.fetch(:payload).fetch(:pending_decisions).first.fetch(:key)).to eq(:scope)
    expect(updated.to_h.fetch(:payload).fetch(:ready_for_writer)).to eq(true)
    expect(workflow.to_h.fetch(:payload).fetch(:current_stage).fetch(:key)).to eq(:implement_pack)
  end
end
