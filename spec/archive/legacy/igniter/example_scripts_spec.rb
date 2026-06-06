# frozen_string_literal: true

require "spec_helper"
require "open3"
require "timeout"

require_relative "../../examples/catalog"

RSpec.describe "Igniter example scripts" do
  def run_example(example)
    stdout = +""
    stderr = +""
    status = nil

    Timeout.timeout(example.timeout) do
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        example.full_path,
        *example.command_args
      )
    end

    [stdout, stderr, status]
  end

  IgniterExamples.smoke.each do |example|
    it "runs #{example.id}" do
      stdout, stderr, status = run_example(example)

      expect(status.success?).to eq(true), stderr
      Array(example.expected_fragments).each do |fragment|
        expect(stdout).to include(fragment)
      end
    end
  end
end
