# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe Igniter::Cluster::Replication::Bootstrappers::Gem do
  let(:bootstrapper) { described_class.new }
  let(:session) { instance_double(Igniter::Cluster::Replication::SSHSession) }
  let(:manifest) do
    Igniter::Cluster::Replication::Manifest.new(
      gem_version: "0.4.5",
      ruby_version: "3.2.0",
      source_path: "/usr/local/bundle/gems/igniter-0.4.5",
      startup_command: "server.rb",
      instance_id: "test-uuid"
    )
  end

  before do
    allow(session).to receive(:exec!)
  end

  describe "#install" do
    it "installs the igniter gem without pinning a version by default" do
      expect(session).to receive(:exec!).with("gem install igniter --no-document")
      bootstrapper.install(session: session, manifest: manifest)
    end

    it "pins the version when specified" do
      bs = described_class.new(version: "0.4.5")
      expect(session).to receive(:exec!).with("gem install igniter -v 0.4.5 --no-document")
      bs.install(session: session, manifest: manifest)
    end

    it "creates the target directory" do
      expect(session).to receive(:exec!).with("mkdir -p /opt/igniter")
      bootstrapper.install(session: session, manifest: manifest)
    end

    it "uses custom target_path" do
      expect(session).to receive(:exec!).with("mkdir -p /srv/igniter")
      bootstrapper.install(session: session, manifest: manifest, target_path: "/srv/igniter")
    end

    it "does not write env file when env is empty" do
      expect(session).not_to receive(:exec!).with(include("export"))
      bootstrapper.install(session: session, manifest: manifest, env: {})
    end

    it "writes env file when env is provided" do
      expect(session).to receive(:exec!).with(include(".env"))
      bootstrapper.install(session: session, manifest: manifest,
                           env: { "SECRET_KEY" => "abc" })
    end
  end

  describe "#start" do
    it "uses igniter-stack as the default startup script" do
      expect(session).to receive(:exec!).with(include("igniter-stack"))
      bootstrapper.start(session: session, manifest: manifest)
    end

    it "uses a custom startup script when specified" do
      bs = described_class.new(startup_script: "my-igniter-app")
      expect(session).to receive(:exec!).with(include("my-igniter-app"))
      bs.start(session: session, manifest: manifest)
    end

    it "runs the process in the background via nohup" do
      expect(session).to receive(:exec!).with(include("nohup"))
      bootstrapper.start(session: session, manifest: manifest)
    end

    it "redirects output to the log file" do
      expect(session).to receive(:exec!).with(include("igniter.log"))
      bootstrapper.start(session: session, manifest: manifest)
    end
  end
end
