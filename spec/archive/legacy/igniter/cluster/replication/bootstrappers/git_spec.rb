# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe Igniter::Cluster::Replication::Bootstrappers::Git do
  let(:repo_url) { "https://github.com/org/igniter-app" }
  let(:bootstrapper) { described_class.new(repo_url: repo_url) }
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
    it "creates the target directory" do
      expect(session).to receive(:exec!).with("mkdir -p /opt/igniter")
      bootstrapper.install(session: session, manifest: manifest)
    end

    it "clones the repository" do
      expect(session).to receive(:exec!).with(
        "git clone --branch main --depth 1 #{repo_url} /opt/igniter/app"
      )
      bootstrapper.install(session: session, manifest: manifest)
    end

    it "installs bundler on the remote" do
      expect(session).to receive(:exec!).with(
        "cd /opt/igniter/app && gem install bundler --no-document"
      )
      bootstrapper.install(session: session, manifest: manifest)
    end

    it "runs bundle install" do
      expect(session).to receive(:exec!).with(
        "cd /opt/igniter/app && bundle install --without development test"
      )
      bootstrapper.install(session: session, manifest: manifest)
    end

    it "uses custom branch when specified" do
      bs = described_class.new(repo_url: repo_url, branch: "production")
      expect(session).to receive(:exec!).with(
        "git clone --branch production --depth 1 #{repo_url} /opt/igniter/app"
      )
      bs.install(session: session, manifest: manifest)
    end

    it "uses custom target_path" do
      expect(session).to receive(:exec!).with("mkdir -p /srv/app")
      bootstrapper.install(session: session, manifest: manifest, target_path: "/srv/app")
    end

    it "does not write env file when env is empty" do
      expect(session).not_to receive(:exec!).with(include("export"))
      bootstrapper.install(session: session, manifest: manifest, env: {})
    end

    it "writes env file when env is provided" do
      expect(session).to receive(:exec!).with(include(".env"))
      bootstrapper.install(session: session, manifest: manifest,
                           env: { "APP_ENV" => "production" })
    end
  end

  describe "#start" do
    it "launches the process in the background via nohup" do
      expect(session).to receive(:exec!).with(include("nohup"))
      bootstrapper.start(session: session, manifest: manifest)
    end

    it "uses the startup_command from the manifest" do
      expect(session).to receive(:exec!).with(include(manifest.startup_command))
      bootstrapper.start(session: session, manifest: manifest)
    end

    it "redirects output to the log file" do
      expect(session).to receive(:exec!).with(include("igniter.log"))
      bootstrapper.start(session: session, manifest: manifest)
    end
  end
end
