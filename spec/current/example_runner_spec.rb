# frozen_string_literal: true

require "spec_helper"
require "open3"

runner_file = File.expand_path("../../examples/run.rb", __dir__)

RSpec.describe "examples runner" do
  let(:runner_path) { runner_file }

  if File.exist?(runner_file)
    it "lists the active smoke examples" do
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, runner_path, "list")

      expect(status.success?).to eq(true), stderr
      expect(stdout).to include("smoke")
      expect(stdout).to include("contracts/basic_pricing")
      expect(stdout).not_to include("smoke       basic_pricing")
    end

    it "runs a single active example by id" do
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, runner_path, "run", "contracts/basic_pricing")

      expect(status.success?).to eq(true), stderr
      expect(stdout).to include("PASSED")
      expect(stdout).to include("Summary: 1 passed, 0 failed, 0 skipped")
    end
  else
    it "is deferred until curated examples transfer" do
      skip "examples/run.rb is not part of the split-era baseline"
    end
  end
end
