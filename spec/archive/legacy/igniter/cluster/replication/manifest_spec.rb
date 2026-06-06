# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe Igniter::Cluster::Replication::Manifest do
  describe ".current" do
    subject(:manifest) { described_class.current }

    it "returns a Manifest" do
      expect(manifest).to be_a(described_class)
    end

    it "has the correct gem_version" do
      expect(manifest.gem_version).to eq(Igniter::VERSION)
    end

    it "has the correct ruby_version" do
      expect(manifest.ruby_version).to eq(RUBY_VERSION)
    end

    it "has a UUID instance_id" do
      expect(manifest.instance_id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "has startup_command set to a string" do
      expect(manifest.startup_command).to be_a(String)
    end

    it "has a source_path that is a string" do
      expect(manifest.source_path).to be_a(String)
    end

    it "is frozen" do
      expect(manifest).to be_frozen
    end

    it "generates a unique instance_id each time" do
      other = described_class.current
      expect(manifest.instance_id).not_to eq(other.instance_id)
    end
  end

  describe "#initialize" do
    subject(:manifest) do
      described_class.new(
        gem_version: "1.2.3",
        ruby_version: "3.2.0",
        source_path: "/srv/app",
        startup_command: "ruby server.rb",
        instance_id: "abc-123"
      )
    end

    it "exposes gem_version" do
      expect(manifest.gem_version).to eq("1.2.3")
    end

    it "exposes ruby_version" do
      expect(manifest.ruby_version).to eq("3.2.0")
    end

    it "exposes source_path" do
      expect(manifest.source_path).to eq("/srv/app")
    end

    it "exposes startup_command" do
      expect(manifest.startup_command).to eq("ruby server.rb")
    end

    it "exposes instance_id" do
      expect(manifest.instance_id).to eq("abc-123")
    end

    it "is frozen" do
      expect(manifest).to be_frozen
    end
  end

  describe "#to_h" do
    it "includes all fields" do
      manifest = described_class.new(
        gem_version: "1.0",
        ruby_version: "3.2",
        source_path: "/app",
        startup_command: "ruby app.rb",
        instance_id: "abc-123"
      )
      expect(manifest.to_h).to eq(
        gem_version: "1.0",
        ruby_version: "3.2",
        source_path: "/app",
        startup_command: "ruby app.rb",
        instance_id: "abc-123"
      )
    end
  end
end
