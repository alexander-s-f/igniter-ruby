# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe Igniter::Cluster::Replication::ReplicationAgent do
  let(:agent)              { described_class.new }
  let(:session_double)     { instance_double(Igniter::Cluster::Replication::SSHSession) }
  let(:bootstrapper_double) { instance_double(Igniter::Cluster::Replication::Bootstrappers::Git) }

  let(:valid_payload) do
    {
      host: "10.0.0.1",
      user: "deploy",
      strategy: :git,
      bootstrapper_options: { repo_url: "https://github.com/org/app" }
    }
  end

  before do
    allow(Igniter::Cluster::Replication::SSHSession).to receive(:new).and_return(session_double)
    allow(Igniter::Cluster::Replication).to receive(:bootstrapper_for).and_return(bootstrapper_double)
    allow(bootstrapper_double).to receive(:install)
    allow(bootstrapper_double).to receive(:start)
    allow(bootstrapper_double).to receive(:verify).and_return(true)
    allow(agent).to receive(:deliver)
  end

  describe "#handle_message with :replicate" do
    it "delivers replication_started before installation" do
      agent.send(:handle_message, { type: :replicate, payload: valid_payload })
      expect(agent).to have_received(:deliver).with(:replication_started, anything)
    end

    it "delivers replication_completed after successful deployment" do
      agent.send(:handle_message, { type: :replicate, payload: valid_payload })
      expect(agent).to have_received(:deliver).with(:replication_completed, anything)
    end

    it "includes host in replication_started event" do
      agent.send(:handle_message, { type: :replicate, payload: valid_payload })
      expect(agent).to have_received(:deliver).with(
        :replication_started, hash_including(host: "10.0.0.1")
      )
    end

    it "includes verified flag in replication_completed event" do
      agent.send(:handle_message, { type: :replicate, payload: valid_payload })
      expect(agent).to have_received(:deliver).with(
        :replication_completed, hash_including(verified: true)
      )
    end

    it "calls bootstrapper install with the session and manifest" do
      agent.send(:handle_message, { type: :replicate, payload: valid_payload })
      expect(bootstrapper_double).to have_received(:install).with(
        session: session_double,
        manifest: instance_of(Igniter::Cluster::Replication::Manifest),
        env: {},
        target_path: "/opt/igniter"
      )
    end

    it "calls bootstrapper start after install" do
      agent.send(:handle_message, { type: :replicate, payload: valid_payload })
      expect(bootstrapper_double).to have_received(:start)
    end

    it "calls bootstrapper verify after start" do
      agent.send(:handle_message, { type: :replicate, payload: valid_payload })
      expect(bootstrapper_double).to have_received(:verify)
    end
  end

  describe "#handle_message with :replicate on SSHError" do
    before do
      allow(bootstrapper_double).to receive(:install).and_raise(
        Igniter::Cluster::Replication::SSHSession::SSHError.new("connection refused")
      )
    end

    it "delivers replication_failed" do
      agent.send(:handle_message, { type: :replicate, payload: valid_payload })
      expect(agent).to have_received(:deliver).with(:replication_failed, anything)
    end

    it "includes the error message in the failure event" do
      agent.send(:handle_message, { type: :replicate, payload: valid_payload })
      expect(agent).to have_received(:deliver).with(
        :replication_failed, hash_including(error: /connection refused/)
      )
    end

    it "does not deliver replication_completed" do
      agent.send(:handle_message, { type: :replicate, payload: valid_payload })
      expect(agent).not_to have_received(:deliver).with(:replication_completed, anything)
    end
  end

  describe "#handle_message with :replicate on missing required field" do
    it "delivers replication_failed when host is missing" do
      payload = valid_payload.reject { |k, _| k == :host }
      agent.send(:handle_message, { type: :replicate, payload: payload })
      expect(agent).to have_received(:deliver).with(:replication_failed, anything)
    end

    it "delivers replication_failed when user is missing" do
      payload = valid_payload.reject { |k, _| k == :user }
      agent.send(:handle_message, { type: :replicate, payload: payload })
      expect(agent).to have_received(:deliver).with(:replication_failed, anything)
    end
  end

  describe "#deliver" do
    it "is defined as a public instance method" do
      expect(agent).to respond_to(:deliver)
    end

    it "does not raise by default" do
      expect { agent.deliver(:some_event, foo: "bar") }.not_to raise_error
    end
  end

  describe "class-level DSL" do
    it "has a :replicate handler registered" do
      expect(described_class.handlers).to have_key(:replicate)
    end

    it "has events: [] as default state" do
      expect(described_class.default_state).to include(events: [])
    end
  end

  describe "MAX_REPLICAS" do
    it "is set to 10" do
      expect(described_class::MAX_REPLICAS).to eq(10)
    end
  end
end
