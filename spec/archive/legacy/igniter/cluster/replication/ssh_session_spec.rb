# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe Igniter::Cluster::Replication::SSHSession do
  let(:host)    { "10.0.0.1" }
  let(:user)    { "deploy" }
  let(:session) { described_class.new(host: host, user: user) }

  let(:ok_status)   { instance_double(Process::Status, success?: true,  exitstatus: 0) }
  let(:fail_status) { instance_double(Process::Status, success?: false, exitstatus: 1) }

  describe "#exec" do
    it "returns a hash with stdout, stderr, success, and exit_code on success" do
      allow(Open3).to receive(:capture3).and_return(["hello\n", "", ok_status])
      result = session.exec("echo hello")
      expect(result).to eq(stdout: "hello\n", stderr: "", success: true, exit_code: 0)
    end

    it "returns success: false on non-zero exit" do
      allow(Open3).to receive(:capture3).and_return(["", "error", fail_status])
      result = session.exec("false")
      expect(result[:success]).to be false
      expect(result[:exit_code]).to eq(1)
    end
  end

  describe "#exec!" do
    it "returns stdout on success" do
      allow(Open3).to receive(:capture3).and_return(["output\n", "", ok_status])
      expect(session.exec!("echo output")).to eq("output\n")
    end

    it "raises SSHError on non-zero exit" do
      allow(Open3).to receive(:capture3).and_return(["", "command not found", fail_status])
      expect { session.exec!("bad_cmd") }.to raise_error(
        Igniter::Cluster::Replication::SSHSession::SSHError,
        /SSH command failed/
      )
    end

    it "includes the failed command in the error message" do
      allow(Open3).to receive(:capture3).and_return(["", "", fail_status])
      expect { session.exec!("rm -rf /") }.to raise_error(
        Igniter::Cluster::Replication::SSHSession::SSHError,
        %r{rm -rf /}
      )
    end
  end

  describe "#upload!" do
    it "does not raise when scp succeeds" do
      allow(Open3).to receive(:capture3).and_return(["", "", ok_status])
      expect { session.upload!("/tmp/file.tar.gz", "/opt/file.tar.gz") }.not_to raise_error
    end

    it "raises SSHError when scp fails" do
      allow(Open3).to receive(:capture3).and_return(["", "lost connection", fail_status])
      expect { session.upload!("/tmp/file.tar.gz", "/opt/file.tar.gz") }.to raise_error(
        Igniter::Cluster::Replication::SSHSession::SSHError,
        /SCP upload failed/
      )
    end
  end

  describe "#test_connection" do
    it "returns true when exec succeeds" do
      allow(Open3).to receive(:capture3).and_return(["ok\n", "", ok_status])
      expect(session.test_connection).to be true
    end

    it "returns false when exec fails" do
      allow(Open3).to receive(:capture3).and_return(["", "refused", fail_status])
      expect(session.test_connection).to be false
    end
  end

  describe "SSH option building" do
    it "includes the correct port in the ssh command" do
      sess = described_class.new(host: host, user: user, port: 2222)
      allow(Open3).to receive(:capture3) do |*args|
        expect(args).to include("-p", "2222")
        ["ok", "", ok_status]
      end
      sess.exec("echo ok")
    end

    it "includes the identity file when key is provided" do
      sess = described_class.new(host: host, user: user, key: "/home/deploy/.ssh/id_rsa")
      allow(Open3).to receive(:capture3) do |*args|
        expect(args).to include("-i", "/home/deploy/.ssh/id_rsa")
        ["ok", "", ok_status]
      end
      sess.exec("echo ok")
    end

    it "does not include -i flag when no key is provided" do
      allow(Open3).to receive(:capture3) do |*args|
        expect(args).not_to include("-i")
        ["ok", "", ok_status]
      end
      session.exec("echo ok")
    end

    it "includes StrictHostKeyChecking=no" do
      allow(Open3).to receive(:capture3) do |*args|
        expect(args).to include("StrictHostKeyChecking=no")
        ["ok", "", ok_status]
      end
      session.exec("echo ok")
    end
  end

  describe "SSHError" do
    it "is a subclass of Igniter::Error" do
      expect(Igniter::Cluster::Replication::SSHSession::SSHError.ancestors).to include(Igniter::Error)
    end
  end
end
