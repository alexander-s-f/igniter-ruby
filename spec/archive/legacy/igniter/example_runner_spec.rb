# frozen_string_literal: true

require "spec_helper"
require "open3"

RSpec.describe "examples runner" do
  let(:runner_path) { File.expand_path("../../examples/run.rb", __dir__) }

  it "lists smoke, manual, and unsupported examples" do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, runner_path, "list")

    expect(status.success?).to eq(true), stderr
    expect(stdout).to include("smoke")
    expect(stdout).to include("manual")
    expect(stdout).to include("unsupported")
    expect(stdout).to include("basic_pricing")
    expect(stdout).to include("replaces basic_pricing")
    expect(stdout).to include("mesh_discovery")
  end

  it "runs a single example by id" do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, runner_path, "run", "basic_pricing")

    expect(status.success?).to eq(true), stderr
    expect(stdout).to include("PASSED")
    expect(stdout).to include("Summary: 1 passed, 0 failed, 0 skipped")
  end
end
