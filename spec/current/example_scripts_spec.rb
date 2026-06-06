# frozen_string_literal: true

require "spec_helper"
require "open3"
require "timeout"

examples_catalog = File.expand_path("../../examples/catalog", __dir__)

if File.exist?("#{examples_catalog}.rb")
  require examples_catalog

  RSpec.describe "active example scripts" do
    def run_example(example)
      stdout = +""
      stderr = +""
      status = nil

      Timeout.timeout(example.timeout) do
        if defined?(Bundler)
          Bundler.with_unbundled_env do
            stdout, stderr, status = Open3.capture3(
              RbConfig.ruby,
              example.full_path,
              *example.command_args
            )
          end
        else
          stdout, stderr, status = Open3.capture3(
            RbConfig.ruby,
            example.full_path,
            *example.command_args
          )
        end
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
else
  RSpec.describe "active example scripts" do
    it "is deferred until curated examples transfer" do
      skip "examples/catalog.rb is not part of the split-era baseline"
    end
  end
end
