# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe "Igniter::Extensions::Contracts pack audit" do
  module CompleteAuditPack
    module_function

    def manifest
      Igniter::Contracts::PackManifest.new(
        name: :complete_audit_pack,
        node_contracts: [Igniter::Contracts::PackManifest.node(:echo)],
        registry_contracts: [Igniter::Contracts::PackManifest.validator(:echo_sources)]
      )
    end

    def install_into(kernel)
      kernel.nodes.register(:echo, Igniter::Contracts::NodeType.new(kind: :echo))
      kernel.dsl_keywords.register(:echo, Igniter::Contracts::DslKeyword.new(:echo) do |name, from:, builder:|
        builder.add_operation(kind: :echo, name: name, from: from.to_sym)
      end)
      kernel.validators.register(:echo_sources, method(:validate_echo_sources))
      kernel.runtime_handlers.register(:echo, method(:handle_echo))
      kernel
    end

    def validate_echo_sources(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
      []
    end

    def handle_echo(operation:, state:, **)
      state.fetch(operation.attributes.fetch(:from).to_sym)
    end
  end

  module IncompleteAuditPack
    module_function

    def manifest
      Igniter::Contracts::PackManifest.new(
        name: :incomplete_audit_pack,
        node_contracts: [Igniter::Contracts::PackManifest.node(:ghost)],
        registry_contracts: [Igniter::Contracts::PackManifest.validator(:ghost_validator)]
      )
    end

    def install_into(kernel)
      kernel
    end
  end

  it "audits a complete pack as ready for finalize" do
    environment = Igniter::Extensions::Contracts.with(Igniter::Extensions::Contracts::DebugPack, CompleteAuditPack)

    audit = Igniter::Extensions::Contracts.audit_pack(CompleteAuditPack, environment)

    expect(audit.ok?).to eq(true)
    expect(audit.installed_in_target_profile).to eq(true)
    expect(audit.draft_registered_keys.fetch(:node_kinds)).to include(:echo)
    expect(audit.missing_registry_contracts).to eq({})
  end

  it "audits an incomplete pack and explains missing seams before finalize" do
    environment = Igniter::Extensions::Contracts.with(Igniter::Extensions::Contracts::DebugPack)

    audit = Igniter::Extensions::Contracts.audit_pack(IncompleteAuditPack, environment)

    expect(audit.ok?).to eq(false)
    expect(audit.installed_in_target_profile).to eq(false)
    expect(audit.missing_node_definitions).to eq([:ghost])
    expect(audit.missing_dsl_keywords).to eq([:ghost])
    expect(audit.missing_runtime_handlers).to eq([:ghost])
    expect(audit.missing_registry_contracts).to eq(validators: [:ghost_validator])
    expect(audit.finalize_error).to include("Igniter::Contracts::IncompletePackError")
    expect(audit.explain).to include("missing node definitions: ghost")
  end
end
