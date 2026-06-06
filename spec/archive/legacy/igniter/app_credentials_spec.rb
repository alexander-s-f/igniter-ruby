# frozen_string_literal: true

require "spec_helper"
require "igniter/app"

RSpec.describe Igniter::App::Credentials do
  describe Igniter::App::Credentials::ConfigLoader do
    around do |example|
      original_openai = ENV["OPENAI_API_KEY"]
      original_anthropic = ENV["ANTHROPIC_API_KEY"]
      original_openai_model = ENV["OPENAI_DEFAULT_MODEL"]
      original_custom = ENV["CUSTOM_SECRET"]
      ENV.delete("OPENAI_API_KEY")
      ENV.delete("ANTHROPIC_API_KEY")
      ENV.delete("OPENAI_DEFAULT_MODEL")
      ENV.delete("CUSTOM_SECRET")
      example.run
    ensure
      ENV["OPENAI_API_KEY"] = original_openai
      ENV["ANTHROPIC_API_KEY"] = original_anthropic
      ENV["OPENAI_DEFAULT_MODEL"] = original_openai_model
      ENV["CUSTOM_SECRET"] = original_custom
    end

    it "loads provider and env mappings from a local credentials file" do
      Dir.mktmpdir do |tmp|
        path = File.join(tmp, "credentials.local.yml")
        File.write(path, <<~YAML)
          openai:
            api_key: sk-openai-local
            default_model: gpt-4.1-mini
          anthropic:
            api_key: sk-ant-local
          env:
            CUSTOM_SECRET: local-value
        YAML

        result = described_class.apply(path)

        expect(result).to include(
          path: path,
          loaded: true,
          applied: {
            "OPENAI_API_KEY" => "sk-openai-local",
            "OPENAI_DEFAULT_MODEL" => "gpt-4.1-mini",
            "ANTHROPIC_API_KEY" => "sk-ant-local",
            "CUSTOM_SECRET" => "local-value"
          }
        )
        expect(ENV["OPENAI_API_KEY"]).to eq("sk-openai-local")
        expect(ENV["OPENAI_DEFAULT_MODEL"]).to eq("gpt-4.1-mini")
        expect(ENV["ANTHROPIC_API_KEY"]).to eq("sk-ant-local")
        expect(ENV["CUSTOM_SECRET"]).to eq("local-value")
      end
    end

    it "does not override an existing environment variable by default" do
      Dir.mktmpdir do |tmp|
        path = File.join(tmp, "credentials.local.yml")
        File.write(path, <<~YAML)
          openai:
            api_key: sk-openai-local
        YAML
        ENV["OPENAI_API_KEY"] = "already-set"

        result = described_class.apply(path)

        expect(result[:applied]).to eq({})
        expect(ENV["OPENAI_API_KEY"]).to eq("already-set")
      end
    end

    it "reports non-secret credential source status" do
      Dir.mktmpdir do |tmp|
        path = File.join(tmp, "credentials.local.yml")
        File.write(path, <<~YAML)
          openai:
            api_key: sk-openai-local
        YAML
        ENV["ANTHROPIC_API_KEY"] = "already-set"

        described_class.apply(path)
        status = described_class.status(path, applied_keys: ["OPENAI_API_KEY"])

        expect(status).to include(
          path: path,
          loaded: true,
          override: false,
          applied_keys: ["OPENAI_API_KEY"]
        )
        expect(status.dig(:providers, :openai)).to include(
          env_key: "OPENAI_API_KEY",
          configured_in_file: true,
          env_present: true,
          source: :local_file
        )
        expect(status.dig(:providers, :anthropic)).to include(
          env_key: "ANTHROPIC_API_KEY",
          env_present: true,
          source: :environment
        )
      end
    end
  end

  describe Igniter::App::Credentials::CredentialPolicy do
    it "serializes and restores a canonical local-only policy" do
      policy = described_class.new(
        name: :local_only,
        label: "Local Only",
        secret_class: :local_only,
        propagation: :disabled,
        route_over_replicate: true,
        weak_trust_behavior: :deny,
        operator_approval_required: true,
        description: "Keep credentials on one node."
      )

      restored = described_class.from_h(policy.to_h)

      expect(restored.to_h).to eq(policy.to_h)
      expect(restored.local_only?).to be(true)
      expect(restored.allows_scope?(:local)).to be(true)
      expect(restored.allows_scope?(:remote)).to be(false)
    end

    it "preserves subclasses when deriving a policy with overrides" do
      subclass = Class.new(described_class)
      policy = subclass.new(
        name: :local_only,
        label: "Local Only",
        secret_class: :local_only,
        propagation: :disabled,
        route_over_replicate: true,
        weak_trust_behavior: :deny,
        operator_approval_required: true
      )

      derived = policy.with(description: "Still local-only")

      expect(derived).to be_a(subclass)
      expect(derived.description).to eq("Still local-only")
    end
  end

  describe Igniter::App::Credentials::Credential do
    it "wraps a credential with a policy object and preserves it through serialization" do
      policy = Igniter::App::Credentials::CredentialPolicy.new(
        name: :local_only,
        label: "Local Only",
        secret_class: :local_only,
        propagation: :disabled,
        route_over_replicate: true,
        weak_trust_behavior: :deny,
        operator_approval_required: true
      )

      credential = described_class.new(
        key: :openai_api,
        label: "OpenAI API",
        provider: :openai,
        scope: :local,
        node: "main",
        policy: policy,
        metadata: { model: "gpt-4o" }
      )

      restored = described_class.from_h(credential.to_h)

      expect(restored.to_h).to eq(credential.to_h)
      expect(restored.allowed_in_scope?(:local)).to be(true)
      expect(restored.allowed_in_scope?(:remote)).to be(false)
    end

    it "preserves credential subclasses when deriving with overrides" do
      subclass = Class.new(described_class)
      policy = Igniter::App::Credentials::CredentialPolicy.new(
        name: :local_only,
        label: "Local Only",
        secret_class: :local_only,
        propagation: :disabled,
        route_over_replicate: true,
        weak_trust_behavior: :deny,
        operator_approval_required: true
      )

      credential = subclass.new(
        key: :openai_api,
        label: "OpenAI API",
        provider: :openai,
        scope: :local,
        policy: policy
      )

      derived = credential.with(metadata: { model: "gpt-4o" })

      expect(derived).to be_a(subclass)
      expect(derived.metadata[:model]).to eq("gpt-4o")
    end
  end

  describe Igniter::App::Credentials::Policies::LocalOnlyPolicy do
    it "provides a canonical node-local policy type" do
      policy = described_class.new

      expect(policy.name).to eq(:local_only)
      expect(policy.local_only?).to be(true)
      expect(policy.allows_scope?(:local)).to be(true)
      expect(policy.allows_scope?(:remote)).to be(false)
      expect(policy.metadata[:notes]).to include("No automatic cross-node credential propagation.")
    end
  end

  describe Igniter::App::Credentials::Policies::EphemeralLeasePolicy do
    it "provides a declared cross-node lease policy without normalizing full replication" do
      policy = described_class.new

      expect(policy.name).to eq(:ephemeral_lease)
      expect(policy.local_only?).to be(false)
      expect(policy.allows_scope?(:local)).to be(true)
      expect(policy.allows_scope?(:remote)).to be(true)
      expect(policy.operator_approval_required).to be(true)
      expect(policy.metadata[:lease_mode]).to eq(:ephemeral)
      expect(policy.metadata[:declared_only]).to be(true)
    end
  end

  describe Igniter::App::Credentials::Events::CredentialEvent do
    it "serializes and restores canonical lease events" do
      event = described_class.new(
        event: :lease_issued,
        credential_key: :openai_api,
        policy_name: :ephemeral_lease,
        node: "main",
        target_node: "replica-1",
        lease_id: "lease-123",
        actor: "operator",
        origin: "dashboard",
        source: :credential_runtime,
        metadata: { ttl_seconds: 300 }
      )

      restored = described_class.from_h(event.to_h)

      expect(restored.to_h).to eq(event.to_h)
      expect(restored.lease_event?).to be(true)
      expect(restored.replication_event?).to be(false)
      expect(restored.granted?).to be(true)
    end

    it "derives denied status for denial events and preserves event subclasses through overrides" do
      subclass = Class.new(described_class)
      event = subclass.new(
        event: :replication_denied,
        credential_key: :openai_api,
        policy_name: :local_only,
        node: "main",
        target_node: "office-edge",
        source: :credential_policy,
        reason: :weak_trust_denied
      )

      derived = event.with(metadata: { trust_class: :weak })

      expect(derived).to be_a(subclass)
      expect(derived.denied?).to be(true)
      expect(derived.replication_event?).to be(true)
      expect(derived.metadata[:trust_class]).to eq(:weak)
    end
  end

  describe Igniter::App::Credentials::LeaseRequest do
    it "serializes and restores canonical lease requests" do
      credential = Igniter::App::Credentials::Credential.new(
        key: :openai_api,
        label: "OpenAI API",
        provider: :openai,
        scope: :local,
        node: "main",
        policy: Igniter::App::Credentials::Policies::EphemeralLeasePolicy.new,
        metadata: { model: "gpt-4o" }
      )

      request = described_class.new(
        credential: credential,
        requested_scope: :remote,
        target_node: "replica-1",
        actor: "ops:alex",
        origin: "operator_console",
        source: :credential_runtime,
        metadata: { ttl_seconds: 300 }
      )

      restored = described_class.from_h(request.to_h)

      expect(restored.to_h).to eq(request.to_h)
      expect(restored.policy_allows_request?).to be(true)
      expect(restored.remote_request?).to be(true)
    end

    it "builds canonical lease request lifecycle events" do
      credential = Igniter::App::Credentials::Credential.new(
        key: :openai_api,
        label: "OpenAI API",
        provider: :openai,
        scope: :local,
        node: "main",
        policy: Igniter::App::Credentials::Policies::LocalOnlyPolicy.new
      )

      request = described_class.new(
        credential: credential,
        target_node: "office-edge",
        actor: "ops:alex",
        origin: "operator_console",
        source: :credential_policy,
        metadata: { approval_required: true }
      )

      expect(request.policy_allows_request?).to be(false)
      expect(request.request_event.to_h).to include(
        event: :lease_requested,
        credential_key: :openai_api,
        policy_name: :local_only,
        target_node: "office-edge"
      )
      expect(request.deny_event(reason: :weak_trust_denied).to_h).to include(
        event: :lease_denied,
        status: :denied,
        reason: :weak_trust_denied
      )
      expect(request.revoke_event(lease_id: "lease-123", reason: :expired).to_h).to include(
        event: :lease_revoked,
        status: :revoked,
        lease_id: "lease-123",
        reason: :expired
      )
    end
  end

  describe Igniter::App::Credentials::Trail do
    it "records canonical credential events and summarizes them" do
      trail = described_class.new

      trail.record(
        event: :lease_requested,
        credential_key: :openai_api,
        policy_name: :ephemeral_lease,
        node: "main",
        target_node: "replica-1",
        source: :credential_runtime
      )
      trail.record(
        event: :lease_denied,
        credential_key: :openai_api,
        policy_name: :local_only,
        node: "main",
        target_node: "office-edge",
        source: :credential_policy,
        reason: :weak_trust_denied
      )

      snapshot = trail.snapshot(limit: 10)

      expect(snapshot).to include(
        total: 2,
        latest_type: :lease_denied,
        latest_status: :denied
      )
      expect(snapshot[:by_event]).to include(lease_requested: 1, lease_denied: 1)
      expect(snapshot[:by_policy]).to include(ephemeral_lease: 1, local_only: 1)
      expect(snapshot[:by_credential]).to include(openai_api: 2)
      expect(snapshot[:by_target_node]).to include("replica-1" => 1, "office-edge" => 1)
    end

    it "supports filtered credential audit snapshots with query metadata" do
      trail = described_class.new

      trail.record(
        event: :lease_requested,
        credential_key: :openai_api,
        policy_name: :ephemeral_lease,
        node: "main",
        target_node: "replica-1",
        source: :credential_runtime
      )
      trail.record(
        event: :lease_denied,
        credential_key: :openai_api,
        policy_name: :local_only,
        node: "main",
        target_node: "office-edge",
        source: :credential_policy,
        reason: :weak_trust_denied
      )

      snapshot = trail.snapshot(
        limit: 1,
        filters: {
          status: :denied,
          policy_name: :local_only,
          target_node: "office-edge"
        },
        order_by: :target_node,
        direction: :desc
      )

      expect(snapshot[:query]).to eq(
        filters: {
          status: [:denied],
          policy_name: [:local_only],
          target_node: ["office-edge"]
        },
        order_by: :target_node,
        direction: :desc,
        limit: 1
      )
      expect(snapshot).to include(
        total: 1,
        latest_type: :lease_denied,
        latest_status: :denied
      )
      expect(snapshot[:events]).to contain_exactly(
        include(
          event: :lease_denied,
          policy_name: :local_only,
          target_node: "office-edge"
        )
      )
    end
  end
end
