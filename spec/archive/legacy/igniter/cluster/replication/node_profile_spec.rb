# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe Igniter::Cluster::Replication::NodeProfile do
  describe ".from_discovery" do
    it "derives capabilities and tags from a discovery snapshot" do
      profile = described_class.from_discovery(
        {
          generated_at: "2026-04-16T10:00:00Z",
          host: {
            hostname: "lab-node-1",
            platform: "arm64-darwin",
            os: "darwin24",
            cpu: "arm64"
          },
          runtime: {
            ruby: {
              engine: "ruby"
            }
          },
          paths: {
            utility_candidates: [
              { name: "ruby", present: true, path: "/usr/bin/ruby" },
              { name: "docker", present: true, path: "/usr/local/bin/docker" },
              { name: "ollama", present: true, path: "/usr/local/bin/ollama" },
              { name: "gcc", present: false, path: nil }
            ],
            discovered_executables: []
          }
        },
        capabilities: [:speech],
        tags: [:portable]
      )

      expect(profile.hostname).to eq("lab-node-1")
      expect(profile.utilities).to include("docker", "ollama", "ruby")
      expect(profile.capabilities).to include(:container_runtime, :local_llm, :ruby, :speech)
      expect(profile.tags).to include(:arm64, :darwin, :portable, :ruby)
      expect(profile.metadata).to eq(generated_at: "2026-04-16T10:00:00Z")
    end
  end

  describe "#capability?" do
    it "checks the derived capability list" do
      profile = described_class.new(capabilities: %i[container_runtime local_llm])
      expect(profile.capability?(:local_llm)).to be true
      expect(profile.capability?(:embedded)).to be false
    end
  end
end
