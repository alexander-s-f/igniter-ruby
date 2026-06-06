# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"
require "fileutils"

RSpec.describe Igniter::Cluster::Replication::Bootstrappers::Tarball do
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

  let(:fake_tarball) { "/tmp/igniter_replication_#{Process.pid}.tar.gz" }

  before do
    allow(session).to receive(:exec!)
    allow(session).to receive(:upload!)
    # Stub tarball creation so we don't need a real source tree
    allow(bootstrapper).to receive(:create_tarball).and_return(fake_tarball)
    # Stub FileUtils.rm_f to avoid filesystem side-effects
    allow(FileUtils).to receive(:rm_f)
  end

  describe "#install" do
    it "creates a local tarball from the manifest source path" do
      expect(bootstrapper).to receive(:create_tarball).with(manifest).and_return(fake_tarball)
      bootstrapper.install(session: session, manifest: manifest)
    end

    it "uploads the tarball to the remote host" do
      expect(session).to receive(:upload!).with(fake_tarball, include("igniter_replication"))
      bootstrapper.install(session: session, manifest: manifest)
    end

    it "creates the target app directory on the remote" do
      expect(session).to receive(:exec!).with("mkdir -p /opt/igniter/app")
      bootstrapper.install(session: session, manifest: manifest)
    end

    it "extracts the tarball on the remote" do
      expect(session).to receive(:exec!).with(include("tar -xzf"))
      bootstrapper.install(session: session, manifest: manifest)
    end

    it "installs bundler on the remote" do
      expect(session).to receive(:exec!).with(
        "cd /opt/igniter/app && gem install bundler --no-document"
      )
      bootstrapper.install(session: session, manifest: manifest)
    end

    it "runs bundle install on the remote" do
      expect(session).to receive(:exec!).with(
        "cd /opt/igniter/app && bundle install --without development test"
      )
      bootstrapper.install(session: session, manifest: manifest)
    end

    it "removes the remote tarball after extraction" do
      expect(session).to receive(:exec!).with(include("rm -f"))
      bootstrapper.install(session: session, manifest: manifest)
    end

    it "cleans up the local tarball even if an error occurs" do
      allow(session).to receive(:upload!).and_raise(
        Igniter::Cluster::Replication::SSHSession::SSHError.new("connection lost")
      )
      expect(FileUtils).to receive(:rm_f).with(fake_tarball)
      expect do
        bootstrapper.install(session: session, manifest: manifest)
      end.to raise_error(Igniter::Cluster::Replication::SSHSession::SSHError)
    end

    it "does not write env file when env is empty" do
      expect(session).not_to receive(:exec!).with(include("export"))
      bootstrapper.install(session: session, manifest: manifest, env: {})
    end

    it "writes env file when env is provided" do
      expect(session).to receive(:exec!).with(include(".env"))
      bootstrapper.install(session: session, manifest: manifest,
                           env: { "RAILS_ENV" => "production" })
    end
  end

  describe "#start" do
    it "runs the process in the background via nohup" do
      expect(session).to receive(:exec!).with(include("nohup"))
      bootstrapper.start(session: session, manifest: manifest)
    end

    it "uses the basename of the startup_command" do
      expect(session).to receive(:exec!).with(include(File.basename(manifest.startup_command)))
      bootstrapper.start(session: session, manifest: manifest)
    end

    it "redirects output to the log file" do
      expect(session).to receive(:exec!).with(include("igniter.log"))
      bootstrapper.start(session: session, manifest: manifest)
    end
  end
end
